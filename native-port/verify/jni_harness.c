/* JNI runtime smoke test WITHOUT a target JDK.
 *
 * Uses the real JDK jni.h so JNINativeInterface_ has the correct field
 * offsets, fills in only the ~10 functions the Box3D bridge actually calls,
 * dlopen()s the cross-compiled .so and runs a gravity-drop simulation.
 * Verifies: ELF load, JNI symbol resolution, scalar math, worker threads,
 * atomics, jlong handle packing and -- critically for s390x/ppc64 -- correct
 * behaviour on BIG ENDIAN targets.
 */
#include <jni.h>
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>

static jsize fake_GetArrayLength(JNIEnv *e, jarray a){ (void)e; return a ? *((jint*)a) : 0; }
static void fake_SetFloatArrayRegion(JNIEnv *e, jfloatArray a, jsize s, jsize n, const jfloat* v){ (void)e;(void)s;(void)n; memcpy(a, v, 13*sizeof(jfloat)); }
static void fake_SetLongArrayRegion(JNIEnv *e, jlongArray a, jsize s, jsize n, const jlong* v){ (void)e;(void)s;(void)n; memcpy(a, v, 2*sizeof(jlong)); }
static jlongArray fake_NewLongArray(JNIEnv *e, jsize n){ (void)e; return (jlongArray)calloc(n, sizeof(jlong)); }
static jfloat* fake_GetFloatArrayElements(JNIEnv *e, jfloatArray a, jboolean* c){ (void)e; if(c)*c=JNI_FALSE; return (jfloat*)a; }
static jint* fake_GetIntArrayElements(JNIEnv *e, jintArray a, jboolean* c){ (void)e; if(c)*c=JNI_FALSE; return (jint*)a; }
static void fake_ReleaseFloatArrayElements(JNIEnv *e, jfloatArray a, jfloat* p, jint m){ (void)e;(void)a;(void)p;(void)m; }
static void fake_ReleaseIntArrayElements(JNIEnv *e, jintArray a, jint* p, jint m){ (void)e;(void)a;(void)p;(void)m; }
static jclass fake_FindClass(JNIEnv *e, const char* n){ (void)e;(void)n; return NULL; }
static jint fake_ThrowNew(JNIEnv *e, jclass c, const char* m){ (void)e;(void)c;(void)m; return 0; }

static struct JNINativeInterface_ V;
static const struct JNINativeInterface_* V_ptr;
static JNIEnv* ENV(void){
    if(!V.GetArrayLength){
        memset(&V,0,sizeof(V));
        V.FindClass = fake_FindClass;
        V.ThrowNew = fake_ThrowNew;
        V.GetArrayLength = fake_GetArrayLength;
        V.NewLongArray = fake_NewLongArray;
        V.GetFloatArrayElements = fake_GetFloatArrayElements;
        V.GetIntArrayElements = fake_GetIntArrayElements;
        V.ReleaseFloatArrayElements = fake_ReleaseFloatArrayElements;
        V.ReleaseIntArrayElements = fake_ReleaseIntArrayElements;
        V.SetFloatArrayRegion = fake_SetFloatArrayRegion;
        V.SetLongArrayRegion = fake_SetLongArrayRegion;
        V_ptr = &V;
    }
    /* In C, JNIEnv == const JNINativeInterface_*, so a JNI function receives
       JNIEnv* == JNINativeInterface_**: the bridge does (*env)->Func(...).
       Hand back a POINTER TO the table pointer, not the table itself. */
    return (JNIEnv*)&V_ptr;
}

typedef jint (*createWorld_t)(JNIEnv*, jclass, jfloat, jfloat, jfloat, jboolean, jboolean);
typedef void (*destroyWorld_t)(JNIEnv*, jclass, jint);
typedef void (*step_t)(JNIEnv*, jclass, jint, jfloat, jint);
typedef jlong (*createBody_t)(JNIEnv*, jclass, jint, jint,
    jfloat,jfloat,jfloat, jfloat,jfloat,jfloat,jfloat, jfloat,jfloat,jfloat,
    jfloat,jfloat,jfloat, jfloat,jfloat, jboolean);
typedef jlong (*addBoxShape_t)(JNIEnv*, jclass, jlong,
    jfloat,jfloat,jfloat, jfloat,jfloat,jfloat,jfloat, jfloat,jfloat,jfloat,
    jfloat,jfloat,jfloat,jfloat, jlong,jlong,jint);
typedef void (*finalizeMass_t)(JNIEnv*, jclass, jlong, jfloat);
typedef void (*readState_t)(JNIEnv*, jclass, jlong, jfloatArray);
typedef void (*destroyBody_t)(JNIEnv*, jclass, jlong);

#define SYM(n) dlsym(h, "Java_lib_kasuga_rendering_models_uml_dynamic_physics_box3d_NativeBox3D_" n)

int main(int argc, char** argv){
    if(argc < 2){ fprintf(stderr,"usage: %s <lib>\n",argv[0]); return 2; }
    void* h = dlopen(argv[1], RTLD_NOW);
    if(!h){ fprintf(stderr,"dlopen: %s\n",dlerror()); return 3; }

    createWorld_t   createWorld   = (createWorld_t)SYM("createWorld");
    destroyWorld_t  destroyWorld  = (destroyWorld_t)SYM("destroyWorld");
    step_t          stepFn        = (step_t)SYM("step");
    createBody_t    createBody    = (createBody_t)SYM("createBody");
    addBoxShape_t   addBoxShape   = (addBoxShape_t)SYM("addBoxShape");
    finalizeMass_t  finalizeMass  = (finalizeMass_t)SYM("finalizeBodyMass");
    readState_t     readState     = (readState_t)SYM("readBodyState");
    destroyBody_t   destroyBody   = (destroyBody_t)SYM("destroyBody");
    if(!(createWorld&&destroyWorld&&stepFn&&createBody&&addBoxShape&&finalizeMass&&readState&&destroyBody)){
        fprintf(stderr,"missing JNI symbol\n"); return 4; }

    jint w = createWorld(ENV(),NULL, 0.f,-10.f,0.f, JNI_TRUE,JNI_TRUE);
    if(!w){ fprintf(stderr,"createWorld failed\n"); return 5; }

    jlong ground = createBody(ENV(),NULL,w,0, 0,0,0, 0,0,0,1, 0,0,0, 0,0,0, 0,0, JNI_FALSE);
    if(!addBoxShape(ENV(),NULL,ground, 0,0,0, 0,0,0,1, 5,0.5f,5, 0,0.5f,0,0, 1,-1,0)) return 6;
    jlong box = createBody(ENV(),NULL,w,2, 0,5,0, 0,0,0,1, 0,0,0, 0,0,0, 0,0, JNI_FALSE);
    if(!addBoxShape(ENV(),NULL,box, 0,0,0, 0,0,0,1, 0.5f,0.5f,0.5f, 1,0.5f,0,0, 1,-1,0)) return 7;
    finalizeMass(ENV(),NULL,box,1.f);

    union { jint n; jfloat f[13]; } buf;
    buf.n = 13;
    readState(ENV(),NULL,box,(jfloatArray)&buf);
    float y0 = buf.f[1];
    printf("initial y = %.6f\n", y0);
    if(!isfinite(y0) || fabsf(y0-5.f)>0.01f){ fprintf(stderr,"BAD initial y (ABI/endian?)\n"); return 8; }

    for(int i=0;i<120;i++) stepFn(ENV(),NULL,w, 1.f/60.f, 4);

    memset(&buf,0,sizeof(buf)); buf.n = 13;
    readState(ENV(),NULL,box,(jfloatArray)&buf);
    int allfinite=1; for(int i=0;i<13;i++) if(!isfinite(buf.f[i])) allfinite=0;
    float y1=buf.f[1], vy=buf.f[9], qw=buf.f[6];
    printf("final   y = %.6f   vy = %.6f   qw = %.6f   finite=%d\n",y1,vy,qw,allfinite);
    if(!allfinite){ fprintf(stderr,"NaN/Inf\n"); return 9; }
    if(!(y1 < y0-0.5f)){ fprintf(stderr,"did not fall\n"); return 10; }
    if(!(y1 > 0.5f && y1 < 1.6f)){ fprintf(stderr,"did not rest on ground: %f\n",y1); return 11; }
    if(!(fabsf(qw-1.f)<0.05f)){ fprintf(stderr,"unexpected rotation\n"); return 12; }

    destroyBody(ENV(),NULL,box); destroyBody(ENV(),NULL,ground); destroyWorld(ENV(),NULL,w);
    printf("PASS: JNI native physics OK\n");
    return 0;
}
