using System.Reflection;
using System.Runtime.InteropServices;

namespace Striplight.Core.Imaging;

/// <summary>Decoded JPEG in a caller-friendly form.</summary>
public sealed record DecodedImage(int Width, int Height, int Channels, byte[] Pixels)
{
    public int Stride => Width * Channels;
}

public sealed class TurboJpegException(string message) : Exception(message);

/// <summary>
/// libjpeg-turbo (TurboJPEG 2.x API) on plain memory buffers — port of uTurboJPEG/uTurboRaw.
/// Every call creates its own handle, so the methods are safe to call from several
/// threads at once. On Windows the bundled <c>libturbojpeg.dll</c> next to the exe is used.
/// </summary>
public static partial class TurboJpeg
{
    private const string Lib = "turbojpeg";

    public const int PixelFormatBgra = 8; // TJPF_BGRA
    public const int PixelFormatGray = 6; // TJPF_GRAY
    private const int SampGray = 3;       // TJSAMP_GRAY
    private const int Samp444 = 0;        // TJSAMP_444
    private const int ColorspaceGray = 2; // TJCS_GRAY
    private const int FlagAccurateDct = 4096;
    private const int FlagProgressive = 16384;

    static TurboJpeg()
    {
        NativeLibrary.SetDllImportResolver(typeof(TurboJpeg).Assembly, Resolve);
    }

    private static IntPtr Resolve(string name, Assembly asm, DllImportSearchPath? path)
    {
        if (name != Lib) return IntPtr.Zero;
        string[] candidates = OperatingSystem.IsWindows()
            ? [Path.Combine(AppContext.BaseDirectory, "libturbojpeg.dll"), "libturbojpeg.dll", "turbojpeg.dll"]
            : OperatingSystem.IsMacOS()
                ? ["libturbojpeg.dylib", "libturbojpeg.0.dylib"]
                : ["libturbojpeg.so.0", "libturbojpeg.so"];
        foreach (var c in candidates)
            if (NativeLibrary.TryLoad(c, out var h)) return h;
        return IntPtr.Zero;
    }

    // C "unsigned long" is 32-bit on Windows and 64-bit on 64-bit Linux: CULong handles both.
    [LibraryImport(Lib)] private static partial IntPtr tjInitCompress();
    [LibraryImport(Lib)] private static partial IntPtr tjInitDecompress();
    [LibraryImport(Lib)] private static partial int tjDestroy(IntPtr handle);
    [LibraryImport(Lib)] private static partial void tjFree(IntPtr buffer);
    [LibraryImport(Lib)] private static partial IntPtr tjGetErrorStr();
    [LibraryImport(Lib)]
    private static unsafe partial int tjCompress2(IntPtr handle, byte* src, int width, int pitch, int height,
        int pixelFormat, ref IntPtr jpegBuf, ref CULong jpegSize, int subsamp, int quality, int flags);
    [LibraryImport(Lib)]
    private static unsafe partial int tjDecompressHeader3(IntPtr handle, byte* jpeg, CULong size,
        out int width, out int height, out int subsamp, out int colorspace);
    [LibraryImport(Lib)]
    private static unsafe partial int tjDecompress2(IntPtr handle, byte* jpeg, CULong size, byte* dst,
        int width, int pitch, int height, int pixelFormat, int flags);

    private static string? _status;

    /// <summary>True when the native library could be loaded.</summary>
    public static bool IsAvailable => Status == "TurboJPEG ready";

    public static string Status
    {
        get
        {
            if (_status is not null) return _status;
            try
            {
                var h = tjInitDecompress();
                if (h != IntPtr.Zero) tjDestroy(h);
                _status = "TurboJPEG ready";
            }
            catch (DllNotFoundException) { _status = "libturbojpeg was not found next to the program."; }
            catch (EntryPointNotFoundException e) { _status = "libturbojpeg is missing a required function: " + e.Message; }
            return _status;
        }
    }

    private static string LastError(string fallback)
    {
        var p = tjGetErrorStr();
        string? s = p == IntPtr.Zero ? null : Marshal.PtrToStringAnsi(p);
        return string.IsNullOrEmpty(s) ? fallback : s;
    }

    /// <summary>Reads width, height and whether the JPEG is grayscale.</summary>
    public static unsafe (int Width, int Height, bool IsGray) ReadHeader(ReadOnlySpan<byte> jpeg)
    {
        var h = tjInitDecompress();
        if (h == IntPtr.Zero) throw new TurboJpegException(LastError("TurboJPEG decode failed."));
        try
        {
            fixed (byte* p = jpeg)
            {
                if (tjDecompressHeader3(h, p, new CULong((nuint)jpeg.Length), out int w, out int ht, out _, out int cs) != 0)
                    throw new TurboJpegException(LastError("TurboJPEG decode failed."));
                return (w, ht, cs == ColorspaceGray);
            }
        }
        finally { tjDestroy(h); }
    }

    /// <summary>
    /// Decodes to 8-bit gray (<see cref="PixelFormatGray"/>) or BGRA. With
    /// <paramref name="requireGrayscaleSource"/> a colour JPEG returns null instead.
    /// </summary>
    public static unsafe DecodedImage? Decode(ReadOnlySpan<byte> jpeg, int pixelFormat, bool requireGrayscaleSource = false)
    {
        var h = tjInitDecompress();
        if (h == IntPtr.Zero) throw new TurboJpegException(LastError("TurboJPEG decode failed."));
        try
        {
            fixed (byte* p = jpeg)
            {
                var size = new CULong((nuint)jpeg.Length);
                if (tjDecompressHeader3(h, p, size, out int w, out int ht, out _, out int cs) != 0)
                    throw new TurboJpegException(LastError("TurboJPEG decode failed."));
                if (w <= 0 || ht <= 0) throw new TurboJpegException("JPEG has invalid dimensions.");
                if (requireGrayscaleSource && cs != ColorspaceGray) return null;

                int channels = pixelFormat == PixelFormatGray ? 1 : 4;
                var pixels = GC.AllocateUninitializedArray<byte>(checked(w * ht * channels));
                fixed (byte* d = pixels)
                {
                    if (tjDecompress2(h, p, size, d, w, w * channels, ht, pixelFormat, FlagAccurateDct) != 0)
                        throw new TurboJpegException(LastError("TurboJPEG decode failed."));
                }
                return new DecodedImage(w, ht, channels, pixels);
            }
        }
        finally { tjDestroy(h); }
    }

    public static DecodedImage? DecodeFile(string path, int pixelFormat, bool requireGrayscaleSource = false) =>
        Decode(File.ReadAllBytes(path), pixelFormat, requireGrayscaleSource);

    /// <summary>Compresses a gray (1 byte/px) or BGRA (4 bytes/px, 4:4:4) buffer to JPEG in memory.</summary>
    public static unsafe byte[] Encode(ReadOnlySpan<byte> pixels, int width, int height, int pitch, int pixelFormat,
        int quality, bool progressive)
    {
        if (width <= 0 || height <= 0) throw new TurboJpegException("Bitmap has invalid dimensions.");
        quality = Math.Clamp(quality, 1, 100);
        int subsamp = pixelFormat == PixelFormatGray ? SampGray : Samp444;
        int flags = FlagAccurateDct | (progressive ? FlagProgressive : 0);

        var h = tjInitCompress();
        if (h == IntPtr.Zero) throw new TurboJpegException(LastError("TurboJPEG encode failed."));
        IntPtr buf = IntPtr.Zero;
        var size = new CULong(0);
        try
        {
            fixed (byte* p = pixels)
            {
                if (tjCompress2(h, p, width, pitch, height, pixelFormat, ref buf, ref size, subsamp, quality, flags) != 0)
                    throw new TurboJpegException(LastError("TurboJPEG encode failed."));
            }
            if (buf == IntPtr.Zero || size.Value == 0) throw new TurboJpegException("TurboJPEG returned an empty JPEG buffer.");
            var result = new byte[(int)size.Value];
            Marshal.Copy(buf, result, 0, result.Length);
            return result;
        }
        finally
        {
            if (buf != IntPtr.Zero) tjFree(buf);
            tjDestroy(h);
        }
    }

    public static byte[] EncodeGray(GrayImage img, int quality, bool progressive) =>
        Encode(img.Data, img.Width, img.Height, img.Width, PixelFormatGray, quality, progressive);
}
