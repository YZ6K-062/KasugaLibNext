// Minimal JNI stub for the IA-64 runtime smoke test.
//
// The C bridge declares its entry points as
//   Java_lib_kasuga_rendering_models_uml_dynamic_physics_box3d_NativeBox3D_<name>
// so this class MUST keep that exact FQN, and every method must be static
// (the second JNI argument is jclass).
//
// This deliberately does NOT depend on slf4j or any KasugaLib class: the smoke
// test can run on a bare IA-64 JDK with nothing but javac + the .so.
package lib.kasuga.rendering.models.uml.dynamic.physics.box3d;

public final class NativeBox3D {
    public static final int STATIC_BODY = 0;
    public static final int KINEMATIC_BODY = 1;
    public static final int DYNAMIC_BODY = 2;

    private NativeBox3D() {}

    public static native int createWorld(float gx, float gy, float gz,
                                         boolean sleeping, boolean continuous);
    public static native void destroyWorld(int worldId);
    public static native void step(int worldId, float timeStep, int subSteps);
    public static native void setGravity(int worldId, float x, float y, float z);

    public static native long createBody(int worldId, int bodyType,
                                         float px, float py, float pz,
                                         float qx, float qy, float qz, float qw,
                                         float vx, float vy, float vz,
                                         float wx, float wy, float wz,
                                         float linearDamping, float angularDamping,
                                         boolean bullet);

    public static native long addBoxShape(long bodyId,
                                          float cx, float cy, float cz,
                                          float qx, float qy, float qz, float qw,
                                          float hx, float hy, float hz,
                                          float density, float friction, float restitution,
                                          float rollingResistance,
                                          long categoryBits, long maskBits, int groupIndex);

    public static native void finalizeBodyMass(long bodyId, float mass);
    public static native void readBodyState(long bodyId, float[] output);
    public static native void destroyBody(long bodyId);
}
