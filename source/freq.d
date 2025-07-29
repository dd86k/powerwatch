module freq;

import core.math : sqrt;
import std.complex : Complex;
import std.math.constants : PI;
import std.math.trigonometry : cos, sin, atan2;
import std.numeric : Fft, fft;
import std.traits : isFloatingPoint;

enum PI2 = PI * 2;
enum PI4 = PI * 4;

// 50 or 60 ±0.5 Hz

// Inspiration: https://halcy.de/blog/2025/02/09/measuring-power-network-frequency-using-junk-you-have-in-your-closet/
// https://gist.github.com/halcy/7fb41ae9457f25eb5d67fa0d2ee57aaf
/* Frequency estimation

# Do a Hann windowed FFT
hann_window = np.hanning(fft_window_size)
windowed = window_samples * hann_window
fft_complex = np.fft.rfft(windowed)

# Slice the magnitude spectrogram to the range we care about
freqs = np.fft.rfftfreq(fft_window_size, 1.0 / sample_rate)
idx_min = np.searchsorted(freqs, FREQ_MIN)
idx_max = np.searchsorted(freqs, FREQ_MAX)
sub_mags = np.abs(fft_complex[idx_min:idx_max])
sub_freqs = freqs[idx_min:idx_max]

# Find the peak
n = np.argmax(sub_mags)

# Quadratic interpolation to refine the peak location
frac_offset = 0.0
if not (n < 1 or n >= len(sub_mags) - 1):
    alpha = sub_mags[n - 1]
    beta  = sub_mags[n]
    gamma = sub_mags[n + 1]
    denom = alpha - 2*beta + gamma
if abs(denom) > 1e-12:
    frac_offset = 0.5 * (alpha - gamma) / denom
n_interp = n + frac_offset

# Compute which frequency this corresponds to
lower_idx = int(np.floor(n_interp))
upper_idx = int(np.ceil(n_interp))
frac = n_interp - lower_idx
if upper_idx >= len(sub_freqs):
    upper_idx = len(sub_freqs) - 1
est_freq = (1 - frac) * sub_freqs[lower_idx] + frac * sub_freqs[upper_idx]
*/

//void find_peak_frequency(double *fft_real, double *fft_imag, int n, uint32_t sample_rate)

/// Calculate the magnitude of a given bin.
/// Params: bin = Selected bin.
/// Returns: Magnitude
F magnitude(F = float)(Complex!F bin)
{
    return sqrt(bin.re * bin.re + bin.im * bin.im);
}

/// Calculate the current phase of a given frequency bin.
/// Params: bin = Selected bin.
/// Returns: Phase
F phase(F = float)(Complex!F bin)
{
    return atan2(bin.im, bin.re); // arctangent
}

// TODO: Deprecate ResultFrame/Result
struct ResultFrame
{
    float magnitude;
    float phase;
}
struct Result
{
    ResultFrame[] frames;
}

// NOTE: Mnemonic to get a clearer picture of operations

// Get frequency given fft/sound parameters.
// e.g., because 44100 samples/s / 64K = ~0.672912598 (frequency resolution for each bin)
float freqresolution(size_t binsize, int samplerate)
{
    return cast(float)samplerate / binsize;
}
unittest
{
    import std.math : isClose;
    assert(isClose(freqresolution(64 * 1024, 44100), 0.672912598));
}

// Get bin to frequency target given its resolution
size_t fftbinidx(int target, size_t binsize, int samplerate)
{
    import std.math : round;
    return cast(size_t)(round(cast(float)target * binsize / samplerate));
}
unittest
{
    assert(fftbinidx(1209, 4 * 1024, 44100) == 112); // 112.3
}

/// Apply a Blackman Window function to a sample.
/// Params:
///   v = Float value between -1.0 to 1.0.
///   n = Index.
///   N = Total amount of samples.
/// Returns: New sample value.
F blackman_window(F = float)(F v, ptrdiff_t n, ptrdiff_t N)
{
    return v * (0.42 - 0.5 * cos(PI2 * n / (N - 1)) + 0.08 * cos(PI4 * n / (N - 1)));
}

/*
The frequencies are all relative to the FFT window.
res[0] is 0 Hz, res[1] corresponds to a sine wave that fits 1 cycle inside your window,
res[2] is 2 cycles etc. The frequency in Hz depends on your sample rate. If it's 44100,
44100 / 4096 = ~10 so your window fits 10 times in 1 second. That means res[1] is
around 10 hz, res[2] 20 hz etc. up to res[4095] which is 40950 hz. Although everything
from res[2048] onwards is just a mirrored copy since 44100 samples/s can only capture
frequencies up to 22 Khz (for more info search 'Nyquist frequency' and 'aliasing').

The closest bucket to 1209Hz is 1209 * (4096 / 44100) = 112.3, which is not an exact
match so it will leak frequencies in all other bins, but it will still mostly contribute
to bins 112 and 113 so it's probably good enough to just check those. If you need better
frequency resolution you can try applying a 'window function' to reduce spectral leakage
or increasing the window size either by including more samples reducing the time resolution,
or by padding the window with 0's which will essentially adds interpolated bins.
*/
class FreqAnalyzer
{
    this(size_t binsize = _32K)
    {
        this.binsize = binsize;
        o = new Fft(binsize);
    }
    
    ResultFrame fft(short[] samples, int rate, int target = 60, bool apply_window = true)
    {
        if (samples.length != binsize) // due to class Fft
            return ResultFrame();
        
        // Apply Blackman window
        if (apply_window)
        {
            int N = cast(int)samples.length;
            for (int i; i < N; i++)
            {
                float f = cast(float)samples[i] / 32767;
                samples[i] = cast(short)(blackman_window!float(f, i, N) * 32767);
            }
        }
        
        // Get bin
        size_t binidx = fftbinidx(target, binsize, rate);
        Complex!float[] bins = o.fft!float(samples); // base-2 sizes only
        if (binidx >= bins.length / 2)
            throw new Exception("Target out of Nyquist frequency");
        Complex!float bin = bins[binidx];
        
        return ResultFrame(magnitude!float(bin), phase!float(bin));
    }
    
    ResultFrame dft(short[] samples, int rate, int target = 60, bool apply_window = true)
    {
        // Apply Blackman window
        if (apply_window)
        {
            int N = cast(int)samples.length;
            for (int i; i < N; i++)
            {
                float f = cast(float)samples[i] / 32767;
                samples[i] = cast(short)(blackman_window!float(f, i, N) * 32767);
            }
        }
        
        int N = cast(int)samples.length;
        int k = cast(int)(cast(float)target / rate * N); // Calculate the bin index for frequency f0
        Complex!float c = Complex!float(0.0, 0.0);
        
        for (size_t n = 0; n < N; n++)
        {
            float angle = PI2 * k * n / N;
            float f = samples[n] / 32767;
            c.re += f * cos(angle);
            c.im -= f * sin(angle);
        }
        
        return ResultFrame(magnitude!float(c), phase!float(c));
    }
    
    /// Perform a Fast Fourier Transform and select bin closest to frequency target.
    /// Params:
    ///   samples = Samples (should be exactly binsize).
    ///   rate = Sampling rate.
    ///   target = Frequency target.
    /// Returns: Bucket for target frequency.
    Complex!F fftfreq(F = float)(F[] samples, int rate, int target)
        if (isFloatingPoint!F)
    {
        if (samples.length != binsize) // due to class Fft
            return Complex!float();
        
        // Get bin
        size_t binidx = fftbinidx(target, binsize, rate);
        scope Complex!F[] bins = o.fft!F(samples); // base-2 sizes only
        if (binidx >= bins.length / 2)
            throw new Exception("Target out of Nyquist frequency");
        return bins[binidx];
    }
    
    /// Perform an Descrete Fourier Transform on target frequency.
    /// Params:
    ///   samples = Samples (should be exactly binsize).
    ///   rate = Sampling rate.
    ///   target = Frequency target.
    /// Returns: Bucket for target frequency.
    Complex!F dftfreq(F = float)(F[] samples, int rate, int target)
        if (isFloatingPoint!F)
    {
        if (samples.length != binsize) // Consistency with fftfreq
            return Complex!float();
        
        int N = cast(int)samples.length;
        int k = cast(int)(cast(F)target / rate * N); // Calculate the bin index for frequency f0
        Complex!F c = Complex!F(0.0, 0.0);
        
        for (size_t n = 0; n < N; n++)
        {
            F angle = PI2 * k * n / N;
            c.re += samples[n] * cos(angle);
            c.im -= samples[n] * sin(angle);
        }
        
        return c;
    }
    
private:
    enum _64K = 1 << 16;
    enum _32K = 1 << 15;
    enum _16K = 1 << 14;
    enum _8K  = 1 << 13;
    enum _4K  = 1 << 12;
    
    size_t binsize;
    Fft o;
}
