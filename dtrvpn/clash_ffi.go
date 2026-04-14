package main

/*
#include <stdlib.h>

// Implemented in jni_callbacks.c — compiled together by CGO
extern void callProtect(void *callback, int fd);
extern void releaseCallback(void *callback);
*/
import "C"
import (
	"context"
	"encoding/json"
	"fmt"
	"net/netip"
	"os"
	"path/filepath"
	"runtime"
	"sync"
	"syscall"
	"time"
	"unsafe"

	"github.com/metacubex/mihomo/common/observable"
	"github.com/metacubex/mihomo/common/utils"
	"github.com/metacubex/mihomo/component/dialer"
	"github.com/metacubex/mihomo/component/process"
	"github.com/metacubex/mihomo/constant"
	"github.com/metacubex/mihomo/hub/executor"
	LC "github.com/metacubex/mihomo/listener/config"
	"github.com/metacubex/mihomo/listener/sing_tun"
	"github.com/metacubex/mihomo/log"
	"github.com/metacubex/mihomo/tunnel"
	"github.com/metacubex/mihomo/tunnel/statistic"
)

// ── Core state ────────────────────────────────────────────────────────────────

var (
	mu      sync.Mutex
	running bool
	homeDir string
)

// ── TUN handler (FlClashX pattern) ────────────────────────────────────────────
// Semaphore(4): close() acquires all 4 slots to drain in-flight protect() calls
// before tearing down the listener — prevents use-after-free on the callback.

type tunHandler struct {
	listener *sing_tun.Listener
	callback unsafe.Pointer // JNI global ref to TunCallback Java object
	sem      chan struct{}   // semaphore: capacity 4
}

func newTunHandler(cb unsafe.Pointer) *tunHandler {
	sem := make(chan struct{}, 4)
	return &tunHandler{callback: cb, sem: sem}
}

// protect calls VpnService.protect(fd) via JNI — runs from any goroutine.
func (h *tunHandler) protect(fd int) {
	h.sem <- struct{}{}
	defer func() { <-h.sem }()
	if h.listener == nil {
		return
	}
	C.callProtect(h.callback, C.int(fd))
}

// close drains the semaphore (waits for in-flight protect calls), then tears down.
func (h *tunHandler) close() {
	// Acquire all 4 slots — blocks until in-flight protect() calls finish
	for i := 0; i < 4; i++ {
		h.sem <- struct{}{}
	}
	removeTunHook()
	if h.listener != nil {
		_ = h.listener.Close()
		h.listener = nil
	}
	if h.callback != nil {
		C.releaseCallback(h.callback)
		h.callback = nil
	}
	// Release slots
	for i := 0; i < 4; i++ {
		<-h.sem
	}
}

var (
	tunMu     sync.Mutex
	activeTun *tunHandler
)

// TUN network settings — must match DTRVpnService.kt VpnService.Builder values.
const (
	tunIpv4CIDR   = "172.19.0.1/30"
	tunDnsAddress = "172.19.0.2"
)

// ── Socket hook (FlClashX pattern) ────────────────────────────────────────────

func installTunHook(h *tunHandler) {
	dialer.DefaultSocketHook = func(network, address string, conn syscall.RawConn) error {
		return conn.Control(func(fd uintptr) {
			tunMu.Lock()
			cur := activeTun
			tunMu.Unlock()
			if cur != nil {
				cur.protect(int(fd))
			}
		})
	}
	// FlClashX: explicitly nil out process resolver so sing_tun never tries
	// to read /data/system/packages.list (forbidden in Android VPN sandbox).
	process.DefaultPackageNameResolver = nil
}

func removeTunHook() {
	dialer.DefaultSocketHook = nil
	process.DefaultPackageNameResolver = nil
}

// ── Traffic speed counter ──────────────────────────────────────────────────────

var (
	trafficMu     sync.Mutex
	prevSnapTime  time.Time
	prevUpTotal   int64
	prevDownTotal int64
	curUpSpeed    int64
	curDownSpeed  int64
)

// ── Mihomo internal log streaming ─────────────────────────────────────────────

var (
	logMu           sync.Mutex
	logBuffer       []string
	logSubscription observable.Subscription[log.Event]
)

// ── Exported functions ─────────────────────────────────────────────────────────

//export InitClash
func InitClash(home *C.char) {
	homeDir = C.GoString(home)
	os.MkdirAll(filepath.Join(homeDir, "mihomo"), 0755)
	constant.SetHomeDir(filepath.Join(homeDir, "mihomo"))
}

// StartClash applies proxy/rules/dns config to Mihomo WITHOUT TUN.
// Call StartTun(fd, cb) separately after this succeeds.
//
//export StartClash
func StartClash(configData *C.char, fd C.int) *C.char {
	mu.Lock()
	defer mu.Unlock()

	if running {
		executor.Shutdown()
		running = false
	}

	trafficMu.Lock()
	prevSnapTime = time.Time{}
	prevUpTotal, prevDownTotal = 0, 0
	curUpSpeed, curDownSpeed = 0, 0
	trafficMu.Unlock()

	yamlStr := C.GoString(configData)

	cfgPath := filepath.Join(constant.Path.HomeDir(), "config.yaml")
	if err := os.WriteFile(cfgPath, []byte(yamlStr), 0644); err != nil {
		return jsonResult(false, err.Error())
	}

	cfg, err := executor.ParseWithBytes([]byte(yamlStr))
	if err != nil {
		return jsonResult(false, fmt.Sprintf("config parse: %v", err))
	}

	executor.ApplyConfig(cfg, true)
	running = true
	return jsonResult(true, "")
}

// StartTun creates the TUN listener (FlClashX pattern).
// fd:  file descriptor from VpnService.Builder.establish().detachFd()
// cb:  JNI global ref to TunCallback Java object — for protect()
//
//export StartTun
func StartTun(fd C.int, cb unsafe.Pointer) *C.char {
	tunMu.Lock()
	defer tunMu.Unlock()

	// Tear down any existing TUN
	if activeTun != nil {
		activeTun.close()
		activeTun = nil
	}

	h := newTunHandler(cb)

	// Install hooks BEFORE creating listener (FlClashX pattern):
	// - protect() hook so every socket sing_tun opens is protected
	// - nil out process resolver so packages.list is never read
	installTunHook(h)
	activeTun = h

	prefix4, err := netip.ParsePrefix(tunIpv4CIDR)
	if err != nil {
		activeTun.close()
		activeTun = nil
		return jsonResult(false, "StartTun: invalid IPv4 prefix: "+err.Error())
	}

	options := LC.Tun{
		Enable:              true,
		// Stack: GVisor — userspace TCP/IP, does NOT require:
		//   - netlink sockets (NetworkUpdateMonitor)
		//   - /data/system/packages.list (android rules)
		// Both of those are forbidden in Android VPN sandbox.
		Stack:               constant.TunGVisor,
		DNSHijack:           []string{tunDnsAddress + ":53"},
		AutoRoute:           false, // Android VpnService handles routing
		AutoDetectInterface: false, // banned in Android sandbox
		Inet4Address:        []netip.Prefix{prefix4},
		MTU:                 9000,
		FileDescriptor:      int(fd),
	}

	listener, err := sing_tun.New(options, tunnel.Tunnel)
	if err != nil {
		activeTun.close()
		activeTun = nil
		return jsonResult(false, "StartTun: sing_tun.New: "+err.Error())
	}

	h.listener = listener
	return jsonResult(true, "")
}

// StopTun closes the TUN listener and removes the socket hook.
//
//export StopTun
func StopTun() {
	tunMu.Lock()
	defer tunMu.Unlock()
	if activeTun != nil {
		activeTun.close()
		activeTun = nil
	}
}

//export StopClash
func StopClash() {
	mu.Lock()
	defer mu.Unlock()
	if running {
		executor.Shutdown()
		running = false
	}
}

//export IsRunning
func IsRunning() C.int {
	if running {
		return 1
	}
	return 0
}

// ValidateConfig parses config and returns "" on success, error string on failure.
//
//export ValidateConfig
func ValidateConfig(configData *C.char) *C.char {
	yaml := C.GoString(configData)
	_, err := executor.ParseWithBytes([]byte(yaml))
	if err != nil {
		return C.CString(err.Error())
	}
	return C.CString("")
}

// UpdateDns — dns.UpdateSystemDNS / FlushCacheWithDefaultResolver are not
// exported in mihomo v1.18.x public releases (only in FlClashX fork).
// We log the request and skip — VPN works fine without it.
//
//export UpdateDns
func UpdateDns(dnsList *C.char) {
	list := C.GoString(dnsList)
	if list == "" {
		return
	}
	log.Infoln("[DNS] UpdateDns requested: %s (skipped, not supported in v1.18.x)", list)
}

// ── Traffic stats ──────────────────────────────────────────────────────────────

//export GetTraffic
func GetTraffic() *C.char {
	trafficMu.Lock()
	defer trafficMu.Unlock()

	snap := statistic.DefaultManager.Snapshot()
	now := time.Now()

	if !prevSnapTime.IsZero() {
		dt := now.Sub(prevSnapTime).Seconds()
		if dt >= 0.05 {
			upDelta := snap.UploadTotal - prevUpTotal
			downDelta := snap.DownloadTotal - prevDownTotal
			if upDelta >= 0 && downDelta >= 0 {
				curUpSpeed = int64(float64(upDelta) / dt)
				curDownSpeed = int64(float64(downDelta) / dt)
			} else {
				curUpSpeed, curDownSpeed = 0, 0
			}
		}
	}

	prevSnapTime = now
	prevUpTotal = snap.UploadTotal
	prevDownTotal = snap.DownloadTotal

	up := curUpSpeed
	if up < 0 {
		up = 0
	}
	down := curDownSpeed
	if down < 0 {
		down = 0
	}

	data, _ := json.Marshal(map[string]int64{"up": up, "down": down})
	return C.CString(string(data))
}

//export GetTotalTraffic
func GetTotalTraffic() *C.char {
	snap := statistic.DefaultManager.Snapshot()
	data, _ := json.Marshal(map[string]int64{
		"up":   snap.UploadTotal,
		"down": snap.DownloadTotal,
	})
	return C.CString(string(data))
}

// ── Mihomo log streaming ───────────────────────────────────────────────────────

//export StartLog
func StartLog() {
	logMu.Lock()
	defer logMu.Unlock()
	if logSubscription != nil {
		return
	}
	logSubscription = log.Subscribe()
	go func() {
		for event := range logSubscription {
			data, err := json.Marshal(map[string]string{
				"level":   event.LogLevel.String(),
				"payload": event.Payload,
				"time":    time.Now().Format("15:04:05.000"),
			})
			if err != nil {
				continue
			}
			logMu.Lock()
			if len(logBuffer) >= 300 {
				logBuffer = logBuffer[1:]
			}
			logBuffer = append(logBuffer, string(data))
			logMu.Unlock()
		}
	}()
}

//export StopLog
func StopLog() {
	logMu.Lock()
	defer logMu.Unlock()
	if logSubscription != nil {
		log.UnSubscribe(logSubscription)
		logSubscription = nil
	}
	logBuffer = nil
}

//export GetPendingLogs
func GetPendingLogs() *C.char {
	logMu.Lock()
	defer logMu.Unlock()
	if len(logBuffer) == 0 {
		return C.CString("[]")
	}
	data, err := json.Marshal(logBuffer)
	if err != nil {
		return C.CString("[]")
	}
	logBuffer = nil
	return C.CString(string(data))
}

// ── Proxy management ───────────────────────────────────────────────────────────

//export SelectProxy
func SelectProxy(group *C.char, proxy *C.char) *C.char {
	groupName := C.GoString(group)
	proxyName := C.GoString(proxy)

	proxies := tunnel.ProxiesWithProviders()
	g, ok := proxies[groupName]
	if !ok {
		return jsonResult(false, "group not found: "+groupName)
	}

	type iSelector interface {
		Set(name string) error
		Now() string
	}
	sel, ok := g.(iSelector)
	if !ok {
		return jsonResult(false, groupName+" is not a selector group")
	}
	if err := sel.Set(proxyName); err != nil {
		return jsonResult(false, err.Error())
	}
	return jsonResult(true, "")
}

// TestDelay tests a single proxy delay (FlClashX pattern).
// Uses proxy.URLTest with utils.NewUnsignedRanges — same as FlClashX handleAsyncTestDelay.
// Returns delay in ms, or -1 on error.
//
//export TestDelay
func TestDelay(proxyName *C.char, testURL *C.char, timeoutMs C.int) C.int {
	name := C.GoString(proxyName)
	url := C.GoString(testURL)
	if url == "" {
		url = "https://www.gstatic.com/generate_204"
	}
	timeout := time.Duration(int(timeoutMs)) * time.Millisecond
	if timeout == 0 {
		timeout = 3 * time.Second
	}

	proxies := tunnel.ProxiesWithProviders()
	p, ok := proxies[name]
	if !ok {
		return -1
	}

	// FlClashX pattern: use utils.NewUnsignedRanges with empty string (accept any status)
	expectedStatus, err := utils.NewUnsignedRanges[uint16]("")
	if err != nil {
		return -1
	}

	ctx, cancel := context.WithTimeout(context.Background(), timeout)
	defer cancel()

	// FlClashX uses proxy.URLTest directly (not a custom interface cast)
	delay, err := p.URLTest(ctx, url, expectedStatus)
	if err != nil || delay == 0 {
		return -1
	}
	return C.int(delay)
}

//export GetProxies
func GetProxies() *C.char {
	type proxyInfo struct {
		Name  string `json:"name"`
		Type  string `json:"type"`
		Alive bool   `json:"alive"`
		Delay uint16 `json:"delay"`
	}

	type iAlive interface{ Alive() bool }
	type iDelay interface{ LastDelay() uint16 }

	var list []proxyInfo
	for name, p := range tunnel.ProxiesWithProviders() {
		alive := true
		var delay uint16
		if a, ok := p.(iAlive); ok {
			alive = a.Alive()
		}
		if d, ok := p.(iDelay); ok {
			delay = d.LastDelay()
		}
		list = append(list, proxyInfo{
			Name:  name,
			Type:  p.Type().String(),
			Alive: alive,
			Delay: delay,
		})
	}

	b, _ := json.Marshal(list)
	return C.CString(string(b))
}

//export ForceGC
func ForceGC() {
	go runtime.GC()
}

//export FreeString
func FreeString(s *C.char) {
	C.free(unsafe.Pointer(s))
}

// ── Helpers ────────────────────────────────────────────────────────────────────

func jsonResult(ok bool, errMsg string) *C.char {
	type result struct {
		OK    bool   `json:"ok"`
		Error string `json:"error,omitempty"`
	}
	b, _ := json.Marshal(result{OK: ok, Error: errMsg})
	return C.CString(string(b))
}

func main() {}
