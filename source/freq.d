module freq;

import core.math : sqrt;
import std.complex : Complex;
import std.math.constants : PI;
import std.math.trigonometry : cos, sin, atan2;
import std.numeric : Fft, fft;
import std.traits : isFloatingPoint;

enum float PI2 = PI * 2;
enum float PI4 = PI * 4;

// 50 or 60 ±0.1 Hz Maximum

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

/// Calculate the magnitude of a given bin.
/// Params: bin = Selected bin.
/// Returns: Magnitude
F magnitude(F = float)(Complex!F bin)
{
    return sqrt(bin.re * bin.re + bin.im * bin.im);
}
// TODO: magnitude unittesting

/// Calculate the current phase of a given frequency bin.
/// Params: bin = Selected bin.
/// Returns: Phase
F phase(F = float)(Complex!F bin)
{
    return atan2(bin.im, bin.re); // arctangent
}
// TODO: phase unittesting

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
size_t fftbinidx(float target, size_t binsize, int samplerate)
{
    import std.math : round;
    return cast(size_t)(round(target * binsize / samplerate));
}
unittest
{
    assert(fftbinidx(1209.0, 4 * 1024 /* 4K bins */, 44100 /* 44.1 kHz */) == 112); // 112.3
}

/// Apply a Blackman Window function to a sample.
/// Params:
///   v = Float value between -1.0 to 1.0.
///   n = Sample index (base-0).
///   N = Total amount of samples (N > 1).
/// Returns: New sample value.
F blackman_window(F = float)(F v, ptrdiff_t n, ptrdiff_t N)
{
    F factor = cast(F)n / (N - 1);
    return v * (0.42 - 0.5 * cos(PI2 * factor) + 0.08 * cos(PI4 * factor));
}

/// Apply a Hann Window function to a sample.
/// Params:
///   v = Float value between -1.0 to 1.0.
///   n = Sample index (base-0).
///   N = Total amount of samples (N > 1).
/// Returns: New sample value.
F hann_window(F = float)(F v, ptrdiff_t n, ptrdiff_t N)
{
    F factor = cast(F)n / (N - 1);
    return v * (0.5 - 0.5 * cos(PI2 * factor));
}

/*
Dlang forum post: (TODO: find URL)

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
    this(size_t binsize)
    {
        this.binsize = binsize;
        o = new Fft(binsize);
    }
    
    Complex!float[] fft(float[] samples)
    {
        if (samples.length != binsize) // due to class Fft
            return throw new Exception("Sample count not 2-based");
        
        return o.fft!float(samples);
    }
    
    // 
    Complex!float[] rfft(float[] samples, int rate = 0, float min = 0.0, float max = 0.0)
    {
        import std.math : round;
        
        //if (samples.length != binsize) // due to class Fft
            //return throw new Exception("Sample count not 2-based");
        
        // TODO: Consider Goertzel algorithm for very sparse bin selection (< ~5% of bins)
        // TODO: Precompute twiddle factors if N is fixed and reused
        // TODO: Use lookup tables for sin/cos if computing many FFTs with the same N
        
        size_t N = samples.length;
        size_t full_bincnt = N / 2 + 1;
        
        // Determine which bins to compute
        size_t start_bin = 0;
        size_t end_bin = full_bincnt;
        
        if (rate > 0 && max > min)
        {
            // Calculate bin indices based on frequency resolution
            // Frequency resolution: rate / N (Hz per bin)
            start_bin = cast(size_t)(round(min * N / rate));
            end_bin = cast(size_t)(round(max * N / rate)) + 1; // +1 to include max bin
            
            // Clamp to valid range
            if (start_bin >= full_bincnt) start_bin = full_bincnt - 1;
            if (end_bin > full_bincnt) end_bin = full_bincnt;
            if (start_bin >= end_bin) start_bin = end_bin - 1;
        }
        
        size_t bins_to_compute = end_bin - start_bin;
        
        // Resize buffer only if needed
        if (rfft_buffer.length < bins_to_compute)
            rfft_buffer.length = bins_to_compute;
        
        float inv_N = 1.0f / N;
        
        // Compute only the requested bins
        foreach (idx; 0 .. bins_to_compute)
        {
            size_t k = start_bin + idx;
            float omega = PI2 * k * inv_N;
            
            float re_sum = 0.0;
            float im_sum = 0.0;
            
            // Optimized inner loop with cached angle increment
            foreach (n; 0 .. N)
            {
                float angle = omega * n;
                re_sum += samples[n] * cos(angle);
                im_sum -= samples[n] * sin(angle);
            }
            
            rfft_buffer[idx] = Complex!float(re_sum, im_sum);
        }
        
        return rfft_buffer[0 .. bins_to_compute];
    }
    
    /// Perform a Fast Fourier Transform and select bin closest to frequency target.
    /// Params:
    ///   samples = Samples (should be exactly binsize).
    ///   rate = Sampling rate.
    ///   target = Frequency target.
    /// Returns: Bucket for target frequency.
    Complex!F fftfreq(F = float)(F[] samples, int rate, float target)
        if (isFloatingPoint!F)
    {
        if (samples.length != binsize) // due to class Fft
            return throw new Exception("Sample count not 2-based");
        
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
    Complex!F rfftfreq(F = float)(F[] samples, int rate, float target)
        if (isFloatingPoint!F)
    {
        if (samples.length != binsize) // Consistency with fftfreq
            return throw new Exception("Sample count not 2-based");
        
        int N = cast(int)samples.length;
        int k = cast(int)(target / rate * N); // Calculate the bin index for frequency f0
        Complex!F c = Complex!F(0.0, 0.0);
        
        for (size_t n; n < N; n++)
        {
            F angle = PI2 * k * n / N;
            c.re += samples[n] * cos(angle);
            c.im -= samples[n] * sin(angle);
        }
        
        return c;
    }
    alias dftfreq = rfftfreq;
    
private:
    enum _64K = 1 << 16;
    enum _32K = 1 << 15;
    enum _16K = 1 << 14;
    enum _8K  = 1 << 13;
    enum _4K  = 1 << 12;
    
    size_t binsize;
    Fft o;
    
    Complex!float[] rfft_buffer;
}

/// Test rfft
unittest
{
    scope FreqAnalyzer a = new FreqAnalyzer(1024);
    
    // Test full spectrum
    float[] test_signal = [1.0, 0.0, -1.0, 0.0];
    auto result = a.rfft(test_signal);
    assert(result.length == 3); // DC, bin1, Nyquist
    
    // Test selective bins with rate
    float[] samples = new float[1024];
    foreach (i; 0 .. 1024)
        samples[i] = sin(PI2 * 1000.0 * i / 44100.0); // 1kHz tone
    
    auto selective = a.rfft(samples, 44100, 900.0, 1100.0);
    assert(selective.length > 0);
    assert(selective.length < 1024 / 2 + 1);
}

/// Quadratic interpolation to refine peak location
/// Returns fractional bin offset from peak_bin (-0.5 to +0.5)
private
float quadraticInterpolation(Complex!float[] fft_bins, size_t peak_bin)
{
    // Need neighbors for interpolation
    if (peak_bin == 0 || peak_bin >= cast(int)fft_bins.length - 1)
        return 0.0f; // Can't interpolate at edges
    
    // Get magnitudes of peak and neighbors
    float alpha = magnitude(fft_bins[peak_bin - 1]);
    float beta  = magnitude(fft_bins[peak_bin]);
    float gamma = magnitude(fft_bins[peak_bin + 1]);
    
    // Parabolic interpolation formula
    // delta = 0.5 * (alpha - gamma) / (alpha - 2*beta + gamma)
    float denom = alpha - 2.0f * beta + gamma;
    
    if (denom == 0.0f)
        return 0.0f; // Flat peak, no interpolation needed
    
    float delta = 0.5f * (alpha - gamma) / denom;
    
    // Clamp to reasonable range (should be -0.5 to +0.5)
    if (delta < -0.5f) delta = -0.5f;
    if (delta > 0.5f) delta = 0.5f;
    
    return delta;
}

/// Find the bin with maximum magnitude in FFT result
private
size_t findPeakBin(Complex!float[] fft_bins)
{
    if (fft_bins.length == 0)
        return 0;
    
    size_t peak_idx = 0;
    float max_mag = magnitude(fft_bins[0]);
    
    foreach (i; 1 .. fft_bins.length)
    {
        float mag = magnitude(fft_bins[i]);
        if (mag > max_mag)
        {
            max_mag = mag;
            peak_idx = i;
        }
    }
    
    return peak_idx;
}

struct Peak
{
    size_t bin;              // Original bin index
    float interpolatedBin;   // Refined bin position (fractional)
    float frequency;         // Interpolated frequency (Hz)
    float magnitude;         // Magnitude at peak
    float magnitudeDB;       // Magnitude in dB
}

/// Complete peak detection with interpolation
/// fft_bins: Output from rfft (only contains bins in the frequency range)
/// start_bin: The bin index where fft_bins[0] corresponds to in the full spectrum
Peak detectPeak(Complex!float[] fft_bins, size_t start_bin, size_t N, int sample_rate)
{
    import std.math : log10;
    
    Peak peak;
    
    // Find bin with maximum magnitude (local index in fft_bins array)
    size_t local_peak = findPeakBin(fft_bins);
    
    // Convert to global bin index
    peak.bin = start_bin + local_peak;
    
    // Quadratic interpolation for sub-bin accuracy (uses local indices)
    float delta = quadraticInterpolation(fft_bins, local_peak);
    
    // Apply interpolation offset to global bin
    peak.interpolatedBin = peak.bin + delta;
    
    // Convert to frequency
    peak.frequency = peak.interpolatedBin * sample_rate / cast(float)N;
    
    // Calculate magnitude
    peak.magnitude = magnitude(fft_bins[local_peak]);
    peak.magnitudeDB = 20.0f * log10(peak.magnitude + float.epsilon); // Add epsilon to avoid log(0)
    
    return peak;
}
