import java.io.*; import java.nio.file.*; import java.util.*;
public class VerifyJar {
  public static void main(String[] a) throws Exception {
    String mapped = System.mapLibraryName("kasuga_box3d");
    String os = System.getProperty("os.name").toLowerCase(Locale.ROOT).contains("win") ? "windows" : "linux";
    String arch = System.getProperty("os.arch").toLowerCase(Locale.ROOT);
    if (arch.equals("amd64")||arch.equals("x86_64")) arch="x86_64";
    else if (arch.equals("aarch64")||arch.equals("arm64")) arch="aarch64";
    String resource = "/native/" + os + "-" + arch + "/" + mapped;
    System.out.println("classifier resource = " + resource);
    try (InputStream in = VerifyJar.class.getResourceAsStream(resource)) {
      if (in == null) throw new IllegalStateException("NOT FOUND in jar: " + resource);
      Path tmp = Files.createTempFile("kasuga-box3d-", ".dll");
      Files.copy(in, tmp, StandardCopyOption.REPLACE_EXISTING);
      tmp.toFile().deleteOnExit();
      System.load(tmp.toAbsolutePath().toString());
      System.out.println("System.load from jar resource OK (" + Files.size(tmp) + " bytes)");
    }
    // call a native method through the JNI stub to prove the loaded lib works
    int w = lib.kasuga.rendering.models.uml.dynamic.physics.box3d.NativeBox3D.createWorld(0f,-10f,0f,true,true);
    lib.kasuga.rendering.models.uml.dynamic.physics.box3d.NativeBox3D.destroyWorld(w);
    System.out.println("PASS: universal jar resource resolves and JNI works");
  }
}
