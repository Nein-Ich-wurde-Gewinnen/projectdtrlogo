#include <jni.h>
#include <stdlib.h>

static JavaVM *gJvm = NULL;

JNIEXPORT jint JNI_OnLoad(JavaVM *vm, void *reserved) {
    gJvm = vm;
    return JNI_VERSION_1_6;
}

void callProtect(void *callback, int fd) {
    if (!gJvm || !callback) return;
    JNIEnv *env = NULL;
    int attached = 0;
    if ((*gJvm)->GetEnv(gJvm, (void **)&env, JNI_VERSION_1_6) != JNI_OK) {
        (*gJvm)->AttachCurrentThread(gJvm, &env, NULL);
        attached = 1;
    }
    jobject obj = (jobject)callback;
    jclass cls = (*env)->GetObjectClass(env, obj);
    jmethodID mid = (*env)->GetMethodID(env, cls, "protect", "(I)V");
    if (mid) (*env)->CallVoidMethod(env, obj, mid, (jint)fd);
    (*env)->DeleteLocalRef(env, cls);
    if (attached) (*gJvm)->DetachCurrentThread(gJvm);
}

void releaseCallback(void *callback) {
    if (!gJvm || !callback) return;
    JNIEnv *env = NULL;
    int attached = 0;
    if ((*gJvm)->GetEnv(gJvm, (void **)&env, JNI_VERSION_1_6) != JNI_OK) {
        (*gJvm)->AttachCurrentThread(gJvm, &env, NULL);
        attached = 1;
    }
    (*env)->DeleteGlobalRef(env, (jobject)callback);
    if (attached) (*gJvm)->DetachCurrentThread(gJvm);
}
