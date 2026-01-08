module powerwatch;

import std.stdio;
import freq;
import wav;
import std.datetime.stopwatch : StopWatch, Duration;
import std.math.constants : PI;
import std.math.trigonometry : cos, sin, atan2;
import std.datetime : DateTime, Duration, dur;
import std.datetime.stopwatch : StopWatch;
import std.datetime.systime : Clock, SysTime;
import std.range : chunks;
import snddrv.asound;
import std.string : startsWith;
import std.conv : text;
import std.complex : Complex;
import core.stdc.string : memcpy;
import core.stdc.stdlib : malloc, free;

// TODO: Analyzer class
//       With buffering (think of "sponge construction", process when full)

struct ReducedDuration
{
    int base;
    string unit;
    
    this(Duration duration)
    {
        if (duration >= dur!"msecs"(1))
        {
            base = cast(int)duration.total!"msecs"();
            unit = "ms";
        }
        else if (duration >= dur!"usecs"(1))
        {
            base = cast(int)duration.total!"usecs"();
            unit = "µs";
        }
        else if (duration >= dur!"hnsecs"(1))
        {
            base = cast(int)duration.total!"hnsecs"();
            unit = "hs";
        }
        else
        {
            base = cast(int)duration.total!"nsecs"();
            unit = "ns";
        }
    }
    
    string toString() const
    {
        import std.format : format;
        return format("%3d %s", base, unit);
    }
}

// HACK: Stop depending on ALSA bits, especially for a port
enum SamplingFormat
{
    s16le = SND_PCM_FORMAT_S16_LE,
    s24le = SND_PCM_FORMAT_S24_LE,
    s32le = SND_PCM_FORMAT_S32_LE,
    f32le = SND_PCM_FORMAT_FLOAT_LE,
}
/*string samplingFormatToString(SamplingFormat fmt)
{
    version (linux)
    final switch (fmt) {
    case SamplingFormat.s16le: return "S16_LE";
    case SamplingFormat.s24le: return "S24_LE";
    case SamplingFormat.s32le: return "S32_LE";
    case SamplingFormat.f32le: return "FLOAT_LE";
    }
    else static assert(0, "sampling format");
}
int samplingFormatToAlsa(SamplingFormat fmt)
{
    version (linux)
    final switch (fmt) {
    case SamplingFormat.s16le: return SND_PCM_FORMAT_S16_LE;
    case SamplingFormat.s24le: return SND_PCM_FORMAT_S24_LE;
    case SamplingFormat.s32le: return SND_PCM_FORMAT_S32_LE;
    case SamplingFormat.f32le: return SND_PCM_FORMAT_FLOAT_LE;
    }
    else static assert(0, "sampling format");
}
int samplingFormatSize(SamplingFormat fmt) {
    final switch (fmt) {
    case SamplingFormat.s16le: return 2;
    case SamplingFormat.s24le: // 3 bytes, but aligned to uint?
    case SamplingFormat.s32le:
    case SamplingFormat.f32le: return 4;
    }
}
immutable SamplingFormat[] SUPPORTED_FORMATS = [
    SamplingFormat.s16le,
    SamplingFormat.s32le,
    SamplingFormat.f32le,
];*/

// TODO: Add "unknown" for learning
enum State { down, up }

/// Get name of dump when writing
string dumpname()
{
    import std.format : format;
    DateTime time = cast(DateTime)Clock.currTime();
    return format("dump_%d-%02d-%02d_%02d%02d%02d.wav",
        time.year, time.month, time.day,
        time.hour, time.minute, time.second);
}
/// Save backbuffer
void dumpbuffer(string path, void *buffer, size_t totalsamples, SamplingFormat fmt,
    size_t pidx, size_t psize, size_t pcount,
    int sample_rate)
{
    ushort bit;
    WavFormat wfmt;
    final switch (fmt) {
    case SamplingFormat.s16le:
        wfmt = WavFormat.pcm;
        bit = 16;
        break;
    case SamplingFormat.s24le:
        wfmt = WavFormat.pcm;
        bit = 24;
        break;
    case SamplingFormat.s32le:
        wfmt = WavFormat.pcm;
        bit = 32;
        break;
    case SamplingFormat.f32le:
        wfmt = WavFormat.ieee_float;
        bit = 32;
        break;
    }
    
    enum CHANNELS = 1;
    
    // HACK: Fixes last "slice" being saved first
    ++pidx;
    
    scope WavWriter writer = new WavWriter(path);
    writer.writeHeader(wfmt, bit, CHANNELS, sample_rate, totalsamples);
    for (size_t t; t < pcount; t++, pidx++)
    {
        if (pidx >= pcount) pidx = 0; // round-trip
        size_t z = pidx * psize;
        final switch (fmt) {
        case SamplingFormat.s16le:
            short[] r = (cast(short*)buffer)[z .. z + psize];
            writer.write!short(r);
            break;
        case SamplingFormat.s24le:
        case SamplingFormat.s32le:
        case SamplingFormat.f32le:
            int[] r = (cast(int*)buffer)[z .. z + psize];
            writer.write!int(r);
            break;
        }
    }
}

void list()
{
    writeln("Input devices (ALSA):");
    scope Asound alsa = new Asound();
    foreach (dev; alsa.listPCMDevices())
    {
        writeln(dev.name);
        
        foreach (desc; dev.descriptions)
        {
            writeln("    ", desc);
        }
        // Test formats
        write("    Formats: ");
        int p;
        foreach (fmt; AFORMATS)
        {
            try if (alsa.samplingFormatAvailableForDevice(dev.name, fmt.format))
            {
                if (p++) write(", ");
                write(fmt.name);
            }
            catch (Exception ex)
            {
                
            }
        }
        writeln();
    }
}

void listAll()
{
    writeln("ALSA device list:");
    foreach (ref dev; new Asound().listDevices())
    {
        writeln("- ", dev.id);
        writeln("  ", dev.driver);
        writeln("  ", dev.name);
        writeln("  ", dev.longname);
        writeln("  ", dev.mixername);
        writeln("  ", dev.components);
        if (dev.pcm_inputs)
        {
            write("  Inputs: ");
            foreach (i, ref pcm; dev.pcm_inputs)
            {
                if (i) write(", ");
                write(pcm);
            }
            writeln();
        }
    }
}

void listen(string device, int sample_rate, int target_frequency, int binsize, bool verbose, string window_name)
{
    // HACK: binsize being period_size
    AsoundConfig config = AsoundConfig(
        sample_rate,
        1,
        binsize,
        SND_PCM_FORMAT_UNKNOWN
    );
    
    // TODO: Automatically determine sample rate
    /*COMMON_SAMPLE_RATES = [
        192000, 176400, 128000, 96000, 88200, 64000,
        48000, 44100, 32000, 22050, 16000, 11025, 8000
    ]*/
    
    scope Asound alsa = new Asound();
    
    // Pick highest quality format
    // TODO: Support BE formats
    static immutable int[] supported = [
        SND_PCM_FORMAT_FLOAT_LE,
        //SND_PCM_FORMAT_S32_LE,
        //SND_PCM_FORMAT_S24_LE,
        SND_PCM_FORMAT_S16_LE,
    ];
    foreach (int fmt; supported)
    {
        if (alsa.samplingFormatAvailableForDevice(device, fmt))
        {
            config.format = fmt;
            break;
        }
    }
    if (config.format == SND_PCM_FORMAT_UNKNOWN)
        throw new Exception("Device has not compatible formats");
    
    // Auto configure channels.
    // If sw (plughw), set channels to one. Otherwise, if hw, autodetect.
    // channels: Real number of channels from listen interface
    // config.channels: Only for setting up listen interface
    bool sw_audio = device.startsWith("plughw:");
    if (sw_audio)
    {
        config.channels = 1;
    }
    else
    {
        // NOTE: Used to be a hack before autodetection in the listen function
        int channels = alsa.getChannelsForDevice(device);
        if (channels == 0) // shouldn't happen, but just in case
        {
            throw new Exception("ALSA returned zero channels for audio PCM device");
        }
        // NOTE: Might not work with hw:
        config.channels = 0; // HACK: do not change channels in alsa by force
    }
    
    
    // Select window function
    float function(float n, ptrdiff_t n, ptrdiff_t N) window;
    switch (window_name) {
    case null, "none": break; // keep null
    case "blackman":
        window = &blackman_window!float;
        break;
    case "hann":
        window = &hann_window!float;
        break;
    default:
        throw new Exception(text("Unknown window function: ", window_name));
    }
    
    // TODO: These should be dynamic settings
    /// Time (seconds) that buffer should hold
    size_t total_time = 20;
    /// Time (seconds) around event
    size_t half_time  = total_time / 2;
    
    // Determine frame size in bytes for incoming buffer input
    size_t frame_size;
    switch (config.format) {
    case SND_PCM_FORMAT_FLOAT_LE, SND_PCM_FORMAT_FLOAT_BE:
    case SND_PCM_FORMAT_S32_LE, SND_PCM_FORMAT_S32_BE:
        frame_size = 4;
        break;
    case SND_PCM_FORMAT_S24_LE, SND_PCM_FORMAT_S24_BE:
        frame_size = 3;
        break;
    case SND_PCM_FORMAT_S16_LE, SND_PCM_FORMAT_S16_BE:
        frame_size = 2;
        break;
    default:
        throw new Exception(text("sizeof ",Asound.formatString(config.format), " unknown"));
    }
    
    // HACK: Make it easier to perform FFT since class Fft only takes base-2 lengths
    //config.period_size = binsize * config.channels ? config.channels : 1;
    
    // NOTE: Function doesn't return, so don't bother releasing memory
    //       System will reclaim it anyway
    
    // Backbuffer size in samples
    // 30 s * 48000 Hz = 1 440 000 samples
    size_t backbuffer_length = total_time * config.sample_rate;
    
    // Setup backbuffer, which SHOULD be circular
    // NOTE: Backbuffer MUST be in FLOAT32 sampling format for consistency
    // TODO: Index should be frame index only, not index of slice
    float *backbuffer = cast(float*)malloc(backbuffer_length * float.sizeof);
    if (backbuffer == null)
        throw new Exception("malloc for backbuffer failed");
    size_t backi;   /// backbuffer "slice" index
    size_t reci;    /// Record/Hold index, up until REC0
    bool holding;   /// If true, we're holding for a recording soon
    
    // Setup analyser bits
    scope FreqAnalyzer analyzer = new FreqAnalyzer(binsize);
    float threshold = 0.0;
    State state = State.up; /// Last known state, assume up
    
    // ALSA buffer
    config.period_size = binsize;
    size_t aframes = config.channels * binsize;
    // TODO: Shouldn't buffer be created callee-side?
    void *abuffer = malloc(aframes * frame_size);
    if (abuffer == null)
        throw new Exception("malloc failed for abuffer");
    
    //
    // Run
    //
    
    // Print info
    if (verbose)
    {
        // TODO: Get configured amount of channels
        stderr.writeln("Listening through ", device, "...");
        stderr.writeln("Ch = ", config.channels, " channel(s)");
        stderr.writeln("Fm = ", Asound.formatString(config.format));
        stderr.writeln("Tf = ", target_frequency, " Hz");
        stderr.writeln("Bs = ", binsize, " bins");
        stderr.writeln("Ps = ", config.period_size, " samples");
        stderr.writeln("Sr = ", config.sample_rate, " samples/second");
        stderr.writeln("Wf = ", window_name ? window_name : "none");
        stderr.writefln("Re = %f Hz/bin", freqresolution(binsize, config.sample_rate));
    }
    
    float target_min = cast(float)target_frequency - 0.5;
    float target_max = cast(float)target_frequency + 0.5;
    
    StopWatch sw;
    sw.start();
    alsa.listen(device, config, abuffer,
    (void *buffer, size_t nframes, ref int astatus)
    {
        if (verbose)
            stderr.writeln("Ac = ", nframes);
        
        // TODO: Warn if nframes != config.period_size
        
        //
        // 1. resample + window
        //
        
        // Destination pointer within backbuffer
        float *dst = backbuffer;
        
        // If we configured with more than one channel,
        // copy only first channel data to force mono-channel
        // TODO: "Smart" seeker struct/class helper to seek better
        //       Hardware (hw:) capture streams could have multiple channels
        //       of any sampling format, so we need to be careful when
        //       filling backbuffer and turn it into a mono channel stream.
        /*if (config.channels > 1)
        {
            short *p = cast(short*)buffer;
            for (size_t i; i < nframes; i++)
                p[i] = p[i * config.channels];
        }*/
        
        sw.reset();
        
        // Change sampling format to F32
        Duration t0 = sw.peek();
        int N = cast(int)nframes;
        switch (config.format) {
        case SND_PCM_FORMAT_FLOAT_LE, SND_PCM_FORMAT_FLOAT_BE:
            float *src = cast(float*)buffer;
            if (window)
            {
                for (int i; i < N; i++)
                {
                    dst[i] = window(src[i], i, N);
                }
            }
            else
            {
                // source AND destination is f32, so just copy
                memcpy(dst, src, nframes * float.sizeof);
            }
            break;
        case SND_PCM_FORMAT_S16_LE, SND_PCM_FORMAT_S16_BE:
            short *src = cast(short*)buffer;
            for (int i; i < N; i++)
            {
                float f = src[i] / 32768.0;
                if (window)
                    f = window(f, i, N);
                dst[i] = f;
            }
            break;
        default:
            throw new Exception(text("not impl: resampling on ", config.format));
        }
        Duration t1 = sw.peek();
        
        if (verbose)
            stderr.writefln("Tt = %s", ReducedDuration(t1 - t0));
        
        //
        // 2. Fourier-transform
        //
        
        Duration t2 = sw.peek();
        // Optimized discrete function
        Complex!float[] bins = analyzer.rfft(backbuffer[0..nframes], config.sample_rate, target_min, target_max);
        Duration t3 = sw.peek();
        
        if (verbose)
            stderr.writefln("Tf = %s", ReducedDuration(t3 - t2));
        
        //
        // 3. Calculate actual frequency of each bin to find minimum and maximum
        //
        
        Duration t4 = sw.peek();
        import std.math : round;
        size_t start_bin = cast(size_t)(round(target_min * nframes / config.sample_rate));
        Peak peak = detectPeak(bins, start_bin, nframes, config.sample_rate);
        Duration t5 = sw.peek();
        
        if (verbose)
        {
            stderr.writefln("Tp = %s", ReducedDuration(t5 - t4));
            stderr.writeln("bins = ", bins);
            stderr.writeln("Peak = ", peak.frequency, " Hz, Mag = ", peak.magnitude, " (", peak.magnitudeDB, " dB)");
        }
    });
}

void analyze(string path, size_t binsize, int target)
{
    import coastas : CostasLoop;
    
    scope WavReader wav = new WavReader(path);
    
    int rate = wav.sampleRate();
    
    // interrim float[] buffer
    float[] inbuffer = new float[binsize];
    
    //
    // Cutoff checking
    //
    // TODO: Redo section with a generic analysis class that does buffering
    scope FreqAnalyzer analyzer = new FreqAnalyzer(binsize);
    bool warning_cutoff = false;
    float timerate = cast(float)binsize/rate; // time rate
    float time = timerate / 2;
    float threshold = 0.0;
    float[] buffer = new float[binsize];
    
    CostasLoop cl = CostasLoop(target - 0.5, target + 0.5);
    
    while (wav.eof() == false)
    {
        float[] chunk = wav.read(buffer);
        
        // last chunk will be not a power of 2
        // could be infilled with zero
        if (chunk.length != binsize)
            break;
        
        Complex!float frame = analyzer.fftfreq(inbuffer, rate, target);
        
        float mag = magnitude!float(frame);
        
        // Take first result as threshold
        if (threshold == 0.0)
        {
            threshold = mag / 4;
            // Even if this is still zero, it'll retry next iteration
            // If there are no results, then maybe the signal is too weak
        }
        
        if (warning_cutoff == false)
        {
            if (mag < threshold)
            {
                stderr.writefln("~%7.3f: DOWN", time);
                warning_cutoff = true;
            }
        }
        else
        {
            if (mag >= threshold)
            {
                stderr.writefln("~%7.3f: UP", time);
                warning_cutoff = false;
            }
        }
        
        time += timerate;
        
        // frequency estimation
        cl.update(chunk, rate);
    }
    
    writefln("Estimated VCO Frequency (CL)  = %.3f Hz", cl.frequency);
}

void info(string path)
{
    scope WavReader wav = new WavReader(path);
    
    FormatChunk fmtchunk = wav.getFormatChunk();
    
    with (fmtchunk) {
    writeln("format        : ", format);
    writeln("channels      : ", channels);
    writeln("samplerate    : ", samplerate);
    writeln("datarate      : ", datarate);
    writeln("blockalign    : ", blockalign);
    writeln("samplebits    : ", samplebits);
    }
    
    writeln("samples       : ", wav.length);
}

void dump(string path, size_t binsize, int target)
{
    scope WavReader wav = new WavReader(path);
    int rate = wav.sampleRate();
    
    float[] inbuffer = new float[binsize];
    
    scope FreqAnalyzer analyzer = new FreqAnalyzer(binsize);
    float timerate = cast(float)binsize/rate; // time rate
    float time = 0.0;
    while (wav.eof() == false)
    {
        float[] chunk = wav.read(inbuffer);
        
        if (chunk.length != binsize)
            break;
        
        Complex!float bin = analyzer.fftfreq(chunk, rate, target);
        
        float t2 = time + timerate;
        
        writefln(" %5d Hz: T=%8.3f-%8.3f, Mg=%10.0f, Ph=%9f",
            target, time, t2, magnitude(bin), phase(bin));
        
        time = t2;
    }
}
