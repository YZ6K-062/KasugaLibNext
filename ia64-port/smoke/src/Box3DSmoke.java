import lib.kasuga.rendering.models.uml.dynamic.physics.box3d.NativeBox3D;

/**
 * Standalone Linux/IA-64 acceptance test for the cross-compiled Box3D JNI lib.
 *
 * A deterministic gravity-drop simulation exercises, in one shot:
 *   - scalar SIMD fallback math (B3_SIMD_NONE on __ia64__)
 *   - __atomic_* atomics and pthread_create worker threads (b3World_Step)
 *   - aligned_alloc / _Alignas(16) stack arrays
 *   - JNI array marshalling (jfloatArray GetArrayLength/SetFloatArrayRegion)
 *   - correct little-endian LP64 jlong/jint packing of Box3D IDs
 *
 * Compile/run with no third-party dependencies; see run_smoke_ia64.sh.
 */
public final class Box3DSmoke {

    private static void check(boolean ok, String what) {
        if (!ok) throw new AssertionError("FAILED: " + what);
        System.out.println("  ok  - " + what);
    }

    public static void main(String[] args) {
        String lib = System.getProperty("kasuga.box3d.library");
        if (lib == null || lib.isEmpty()) {
            throw new IllegalArgumentException("set -Dkasuga.box3d.library=/abs/path/libkasuga_box3d.so");
        }

        String osName = System.getProperty("os.name", "").toLowerCase(java.util.Locale.ROOT);
        String archName = System.getProperty("os.arch", "").toLowerCase(java.util.Locale.ROOT);
        String os = osName.contains("win") ? "windows"
                : osName.contains("mac") || osName.contains("darwin") ? "macos"
                : osName.contains("linux") ? "linux"
                : osName.replaceAll("[^a-z0-9_-]", "_");
        String arch = switch (archName) {
            case "amd64", "x86_64" -> "x86_64";
            case "aarch64", "arm64" -> "aarch64";
            default -> archName.replaceAll("[^a-z0-9_-]", "_");
        };
        String classifier = os + "-" + arch;

        System.out.println("=== Box3D native runtime smoke test ===");
        System.out.println("  os.name        = " + System.getProperty("os.name"));
        System.out.println("  os.arch        = " + System.getProperty("os.arch"));
        System.out.println("  classifier     = " + classifier);
        System.out.println("  data model     = " + System.getProperty("sun.arch.data.model"));
        System.out.println("  java.vm.name   = " + System.getProperty("java.vm.name"));
        System.out.println("  vm.version     = " + System.getProperty("java.vm.version"));

        System.load(lib);
        check(true, "System.load(" + lib + ")");

        int world = 0;
        long ground = 0L, box = 0L;
        try {
            world = NativeBox3D.createWorld(0f, -10f, 0f, true, true);
            check(world != 0, "createWorld returned a valid packed id (" + world + ")");

            // Static ground slab: top surface at y = +0.5
            ground = NativeBox3D.createBody(world, NativeBox3D.STATIC_BODY,
                    0f, 0f, 0f, 0f, 0f, 0f, 1f,
                    0f, 0f, 0f, 0f, 0f, 0f, 0f, 0f, false);
            check(ground != 0L, "createBody(STATIC) returned a valid packed id");
            long groundShape = NativeBox3D.addBoxShape(ground,
                    0f, 0f, 0f, 0f, 0f, 0f, 1f,
                    5f, 0.5f, 5f, 0f, 0.5f, 0f, 0f,
                    1L, -1L, 0);
            check(groundShape != 0L, "addBoxShape(ground) succeeded");

            // Dynamic box dropped from y = 5, half extent 0.5
            box = NativeBox3D.createBody(world, NativeBox3D.DYNAMIC_BODY,
                    0f, 5f, 0f, 0f, 0f, 0f, 1f,
                    0f, 0f, 0f, 0f, 0f, 0f, 0f, 0f, false);
            check(box != 0L, "createBody(DYNAMIC) returned a valid packed id");
            long boxShape = NativeBox3D.addBoxShape(box,
                    0f, 0f, 0f, 0f, 0f, 0f, 1f,
                    0.5f, 0.5f, 0.5f, 1f, 0.5f, 0f, 0f,
                    1L, -1L, 0);
            check(boxShape != 0L, "addBoxShape(box) succeeded");
            NativeBox3D.finalizeBodyMass(box, 1f);
            check(true, "finalizeBodyMass did not fault");

            float[] state = new float[13];
            NativeBox3D.readBodyState(box, state);
            float y0 = state[1];
            System.out.println("  initial y     = " + y0);
            check(Float.isFinite(y0) && Math.abs(y0 - 5f) < 0.01f,
                    "initial position read back correctly via jfloatArray");

            // 2 seconds @ 60 Hz. Exercises the worker/scheduler threads.
            for (int i = 0; i < 120; i++) {
                NativeBox3D.step(world, 1f / 60f, 4);
            }
            check(true, "120 x step() with 4 substeps (worker threads, atomics)");

            state = new float[13];
            NativeBox3D.readBodyState(box, state);
            boolean allFinite = true;
            for (float v : state) allFinite &= Float.isFinite(v);
            check(allFinite, "all 13 state floats are finite (no NaN/Inf from scalar math)");

            float y1 = state[1];
            System.out.println("  final y       = " + y1);
            check(y1 < y0 - 0.5f, "box actually fell under gravity");
            // ground top 0.5 + box half-height 0.5 = resting centre ~1.0
            check(y1 > 0.5f && y1 < 1.6f,
                    "box came to rest on the ground (expected ~1.0, got " + y1 + ")");

            System.out.println("  final vy      = " + state[9]);
            System.out.println("  quaternion w  = " + state[6]);
            check(Math.abs(state[6] - 1f) < 0.05f, "rotation stayed identity (no torque)");
        } finally {
            if (box != 0L) NativeBox3D.destroyBody(box);
            if (ground != 0L) NativeBox3D.destroyBody(ground);
            if (world != 0) NativeBox3D.destroyWorld(world);
            System.out.println("  ok  - teardown (destroyBody/destroyWorld)");
        }

        System.out.println("=== PASS: Box3D native physics works on " + classifier + " ===");
    }
}
