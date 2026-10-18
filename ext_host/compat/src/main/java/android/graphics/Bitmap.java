package android.graphics;

import java.io.OutputStream;

/**
 * Image processing is not available in this host yet: creating or decoding a
 * bitmap fails with UnsupportedOperationException, which the extension sees as
 * an ordinary error on that page.
 */
public final class Bitmap {
    public enum Config { ALPHA_8, RGB_565, ARGB_4444, ARGB_8888, RGBA_F16, HARDWARE }

    public enum CompressFormat { JPEG, PNG, WEBP, WEBP_LOSSY, WEBP_LOSSLESS }

    private Bitmap() {
    }

    static UnsupportedOperationException unsupported() {
        return new UnsupportedOperationException("image processing is not available in this host");
    }

    public static Bitmap createBitmap(int width, int height, Config config) { throw unsupported(); }
    public static Bitmap createBitmap(Bitmap source, int x, int y, int width, int height) { throw unsupported(); }
    public static Bitmap createScaledBitmap(Bitmap src, int dstWidth, int dstHeight, boolean filter) { throw unsupported(); }
    public int getWidth() { throw unsupported(); }
    public int getHeight() { throw unsupported(); }
    public int getPixel(int x, int y) { throw unsupported(); }
    public boolean compress(CompressFormat format, int quality, OutputStream stream) { throw unsupported(); }
    public void recycle() { }
}
