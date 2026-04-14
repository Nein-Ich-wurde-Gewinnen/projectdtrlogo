#include <jni.h>
#include <stdlib.h>

extern void  InitClash       (const char *home);
extern char *StartClash      (const char *configData, int fd);
extern void  StopClash       (void);
extern int   IsRunning       (void);
extern char *StartTun        (int fd, void *cb);
extern void  StopTun         (void);
extern char *SelectProxy     (const char *group, const char *proxy);
extern int   TestDelay       (const char *proxyName, const char *testURL, int timeoutMs);
extern char *GetProxies      (void);
extern char *GetTraffic      (void);
extern char *GetTotalTraffic (void);
extern void  ForceGC         (void);
extern char *ValidateConfig  (const char *configData);
extern void  StartLog        (void);
extern void  StopLog         (void);
extern char *GetPendingLogs  (void);

#define PKG "online/dtr/vpn/DTRVpnService"
#define JNI(name) Java_online_dtr_vpn_DTRVpnService_##name

JNIEXPORT void JNICALL JNI(initClash)(JNIEnv *e, jobject o, jstring home) {
    const char *s = (*e)->GetStringUTFChars(e, home, 0);
    InitClash(s);
    (*e)->ReleaseStringUTFChars(e, home, s);
}

JNIEXPORT jstring JNICALL JNI(startClash)(JNIEnv *e, jobject o, jstring cfg, jint fd) {
    const char *s = (*e)->GetStringUTFChars(e, cfg, 0);
    char *r = StartClash(s, (int)fd);
    (*e)->ReleaseStringUTFChars(e, cfg, s);
    jstring js = (*e)->NewStringUTF(e, r);
    free(r);
    return js;
}

JNIEXPORT void JNICALL JNI(stopClash)(JNIEnv *e, jobject o) { StopClash(); }

JNIEXPORT jint JNICALL JNI(isClashRunning)(JNIEnv *e, jobject o) { return IsRunning(); }

// StartTun: fd + TunCallback object for VpnService.protect()
JNIEXPORT jstring JNICALL JNI(startTun)(JNIEnv *e, jobject o, jint fd, jobject cb) {
    // Create global ref so Go can call protect() from any thread
    jobject globalCb = (*e)->NewGlobalRef(e, cb);
    char *r = StartTun((int)fd, (void *)globalCb);
    jstring js = (*e)->NewStringUTF(e, r);
    free(r);
    return js;
}

JNIEXPORT void JNICALL JNI(stopTun)(JNIEnv *e, jobject o) { StopTun(); }

JNIEXPORT jstring JNICALL JNI(selectProxy)(JNIEnv *e, jobject o, jstring g, jstring p) {
    const char *gs = (*e)->GetStringUTFChars(e, g, 0);
    const char *ps = (*e)->GetStringUTFChars(e, p, 0);
    char *r = SelectProxy(gs, ps);
    (*e)->ReleaseStringUTFChars(e, g, gs);
    (*e)->ReleaseStringUTFChars(e, p, ps);
    jstring js = (*e)->NewStringUTF(e, r);
    free(r);
    return js;
}

JNIEXPORT jint JNICALL JNI(testDelay)(JNIEnv *e, jobject o, jstring name, jstring url, jint ms) {
    const char *ns = (*e)->GetStringUTFChars(e, name, 0);
    const char *us = (*e)->GetStringUTFChars(e, url, 0);
    jint r = TestDelay(ns, us, (int)ms);
    (*e)->ReleaseStringUTFChars(e, name, ns);
    (*e)->ReleaseStringUTFChars(e, url, us);
    return r;
}

JNIEXPORT jstring JNICALL JNI(getProxies)(JNIEnv *e, jobject o) {
    char *r = GetProxies();
    jstring js = (*e)->NewStringUTF(e, r);
    free(r);
    return js;
}

JNIEXPORT jstring JNICALL JNI(getTraffic)(JNIEnv *e, jobject o) {
    char *r = GetTraffic();
    jstring js = (*e)->NewStringUTF(e, r);
    free(r);
    return js;
}

JNIEXPORT jstring JNICALL JNI(getTotalTraffic)(JNIEnv *e, jobject o) {
    char *r = GetTotalTraffic();
    jstring js = (*e)->NewStringUTF(e, r);
    free(r);
    return js;
}

JNIEXPORT void JNICALL JNI(forceGC)(JNIEnv *e, jobject o) { ForceGC(); }

JNIEXPORT jstring JNICALL JNI(validateConfig)(JNIEnv *e, jobject o, jstring cfg) {
    const char *s = (*e)->GetStringUTFChars(e, cfg, 0);
    char *r = ValidateConfig(s);
    (*e)->ReleaseStringUTFChars(e, cfg, s);
    jstring js = (*e)->NewStringUTF(e, r);
    free(r);
    return js;
}

JNIEXPORT void JNICALL JNI(startLog)(JNIEnv *e, jobject o) { StartLog(); }
JNIEXPORT void JNICALL JNI(stopLog)(JNIEnv *e, jobject o) { StopLog(); }

JNIEXPORT jstring JNICALL JNI(getPendingLogs)(JNIEnv *e, jobject o) {
    char *r = GetPendingLogs();
    jstring js = (*e)->NewStringUTF(e, r);
    free(r);
    return js;
}
