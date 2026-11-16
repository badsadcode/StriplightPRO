using Striplight.Core.Imaging;

namespace Striplight.Core.Tests;

public class ToneAdjustTests
{
    [Fact]
    public void NeutralStriplightLutIsIdentity()
    {
        var lut = ToneAdjust.BuildLut(ToneMethod.Striplight, 0, 0, 0, 100);
        for (int i = 0; i < 256; i++) Assert.Equal(i, lut[i]);
    }

    [Fact]
    public void NeutralQuantumLutIsIdentity()
    {
        var lut = ToneAdjust.BuildLut(ToneMethod.Quantum, 0, 64, 0, 0);
        for (int i = 0; i < 256; i++) Assert.Equal(i, lut[i]);
    }

    [Fact]
    public void CurveKeepsEndpointsAndLiftsMidtones()
    {
        var lut = ToneAdjust.BuildLut(ToneMethod.Curve, 0, 0, 0, 100);
        Assert.Equal(0, lut[0]);
        Assert.Equal(255, lut[255]);
        Assert.True(lut[64] > 64);
    }

    [Theory]
    [InlineData(ToneMethod.Striplight, 0, 0, 100, 50, true)]
    [InlineData(ToneMethod.Quantum, 64, 0, 0, 50, true)]
    [InlineData(ToneMethod.Curve, 0, 0, 100, 50, false)]
    [InlineData(ToneMethod.AutoLevels, 0, 0, 100, 0, false)]
    [InlineData(ToneMethod.Clahe, 0, 0, 100, 0, true)]
    [InlineData(ToneMethod.Clahe, 0, 0, 100, 10, false)]
    public void NoOpDetection(int method, int c, int b, int g, int s, bool expected) =>
        Assert.Equal(expected, ToneAdjust.IsNoOp(method, 0, c, b, g, s));

    [Fact]
    public void AnyFlagIsNeverNoOp() => Assert.False(ToneAdjust.IsNoOp(0, (int)ToneFlags.SCurve, 0, 0, 100, 0));

    [Fact]
    public void AutoLevelsStretchesNarrowRange()
    {
        int w = 64, h = 64;
        var data = new byte[w * h];
        for (int i = 0; i < data.Length; i++) data[i] = (byte)(80 + (i % 100));
        ToneAdjust.ApplyToneGray(data, w, h, w, new ToneSettings(ToneMethod.AutoLevels, 0, 0, 0, 100, 0), false);
        Assert.Equal(0, data.Min());
        Assert.Equal(255, data.Max());
    }

    [Theory]
    [InlineData(ToneMethod.Clahe)]
    [InlineData(ToneMethod.LocalExposure)]
    [InlineData(ToneMethod.BackgroundFlatten)]
    public void AdaptiveMethodsRunOnGradient(int method)
    {
        int w = 300, h = 200;
        var data = new byte[w * h];
        for (int y = 0; y < h; y++)
            for (int x = 0; x < w; x++)
                data[y * w + x] = (byte)(40 + x * 150 / w + ((x / 7 + y / 7) % 2) * 30);
        var before = (byte[])data.Clone();
        ToneAdjust.ApplyToneGray(data, w, h, w, new ToneSettings(method, 0, 0, 0, 100, 60), false);
        Assert.NotEqual(before, data);
    }

    [Fact]
    public void ZeroStrengthAdaptiveIsUnchanged()
    {
        var data = Enumerable.Range(0, 64 * 64).Select(i => (byte)(i % 256)).ToArray();
        var before = (byte[])data.Clone();
        ToneAdjust.ApplyToneGray(data, 64, 64, 64, new ToneSettings(ToneMethod.LocalExposure, 0, 0, 0, 100, 0), false);
        Assert.Equal(before, data);
    }
}

public class GrayImageTests
{
    // 3 wide x 2 high:
    // 1 2 3
    // 4 5 6
    private static GrayImage Sample() => new(3, 2, new byte[] { 1, 2, 3, 4, 5, 6 });

    [Fact]
    public void Rotate90Clockwise()
    {
        var img = Sample();
        img.Orient(90, false, false);
        Assert.Equal((2, 3), (img.Width, img.Height));
        Assert.Equal(new byte[] { 4, 1, 5, 2, 6, 3 }, img.Data);
    }

    [Fact]
    public void Rotate270()
    {
        var img = Sample();
        img.Orient(270, false, false);
        Assert.Equal(new byte[] { 3, 6, 2, 5, 1, 4 }, img.Data);
    }

    [Fact]
    public void Rotate180AndFlips()
    {
        var img = Sample();
        img.Orient(180, false, false);
        Assert.Equal(new byte[] { 6, 5, 4, 3, 2, 1 }, img.Data);
        img.Orient(0, true, false);
        Assert.Equal(new byte[] { 4, 5, 6, 1, 2, 3 }, img.Data);
        img.Orient(0, false, true);
        Assert.Equal(new byte[] { 1, 2, 3, 4, 5, 6 }, img.Data);
    }

    [Fact]
    public void BlitTransposeAndCcw()
    {
        var src = new byte[] { 1, 2, 3, 4, 5, 6 }; // 3x2
        var t = new GrayImage(2, 3);
        t.BlitRotated(src, 3, 2, new IntRect(0, 0, 3, 2), transpose: true, dstX: 0);
        Assert.Equal(new byte[] { 1, 4, 2, 5, 3, 6 }, t.Data);

        var c = new GrayImage(2, 3);
        c.BlitRotated(src, 3, 2, new IntRect(0, 0, 3, 2), transpose: false, dstX: 0);
        Assert.Equal(new byte[] { 3, 6, 2, 5, 1, 4 }, c.Data);
    }

    [Fact]
    public void SharpenLeavesFlatImageAlone()
    {
        var img = new GrayImage(10, 10);
        Array.Fill(img.Data, (byte)120);
        img.Sharpen(2, 80);
        Assert.All(img.Data, b => Assert.Equal(120, b));
    }

    [Fact]
    public void NegativeInverts()
    {
        var img = Sample();
        img.Negative();
        Assert.Equal(new byte[] { 254, 253, 252, 251, 250, 249 }, img.Data);
    }
}
