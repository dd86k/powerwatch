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

void listen(string device, AsoundConfig config, int targetfreq, int binsize, bool verbose)
{
    scope Asound alsa = new Asound();
    
    // Pick highest quality format
    if (config.format == SND_PCM_FORMAT_UNKNOWN)
    {
        // TODO: Support BE formats
        // Supported formats
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
    
    // TODO: These should be dynamic settings
    enum AMT = 20;  // number of record "slices" for backbuffer.
                    // typically, a "slice" is an amount of frames, containing samples.
                    // 32K * 20 = 655360 samples
                    // 655360 @ 48000 s/s = ~13.65 secs
    enum REC0 = AMT / 2;    // record after this many "slices" have passed.
                            // the event should be around the middle
    
    size_t frame_size; /// source frame size in Bytes
    switch (config.format) {
    case SND_PCM_FORMAT_FLOAT_LE:
        frame_size = float.sizeof;
        break;
    case SND_PCM_FORMAT_S16_LE:
        frame_size = short.sizeof;
        break;
    default:
        throw new Exception(text("sizeof ",Asound.formatString(config.format), " unknown"));
    }
    
    bool apply_window = true;
    
    // HACK: Make it easier to perform FFT since class Fft only takes base-2 lengths
    //config.period_size = binsize * config.channels ? config.channels : 1;
    
    import core.stdc.stdlib : malloc, free;
    // NOTE: Function doesn't return, so don't bother releasing memory
    //       System will reclaim it anyway
    
    // Setup backbuffer, which SHOULD be circular
    // NOTE: Backbuffer MUST be in FLOAT32 sampling format for consistency
    // TODO: Index should be frame index only, not index of slice
    size_t backbuffer_length = config.period_size * AMT;
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
    
    // Print info
    if (verbose)
    {
        // TODO: Get configured amount of channels
        stderr.writeln("Listening through ", device, "...");
        stderr.writeln("Ch = ", config.channels);
        stderr.writeln("Fm = ", Asound.formatString(config.format));
        stderr.writeln("Tf = ", targetfreq);
        stderr.writeln("Bs = ", binsize);
        stderr.writeln("Ps = ", config.period_size);
        stderr.writeln("Sr = ", config.sample_rate);
        stderr.writefln("Re = %f", freqresolution(binsize, config.sample_rate));
    }
    
    // ALSA buffer
    size_t aframes = config.channels * config.period_size;
    // TODO: Shouldn't buffer be created callee-side?
    void *abuffer = malloc(aframes * frame_size);
    if (abuffer == null)
        throw new Exception("malloc failed for abuffer");
    
    // TODO: Find peak + alignment before continuing monitoring
    
    StopWatch sw;
    sw.start();
    alsa.listen(device, config, abuffer,
    (void *buffer, size_t nframes, ref int astatus)
    {
        // Copy period time to back buffer
        import core.stdc.string : memcpy;
        
        if (backi >= AMT) backi = 0; // round-trip
        
        // TODO: Fix fixed-buffer approach for backbuffer
        //       If there is an incomplete number of frames available,
        //       it means we'll see gaps of silence between "slices"
        
        // Destination pointer within backbuffer
        float *dst = backbuffer + (backi * config.period_size);
        
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
        
        int N = cast(int)nframes;
        
        // Change from this source to F32 as destination for FFT/DFT
        switch (config.format) {
        case SND_PCM_FORMAT_FLOAT_LE, SND_PCM_FORMAT_FLOAT_BE:
            float *src = cast(float*)buffer;
            if (apply_window)
            {
                for (int i; i < N; i++)
                {
                    dst[i] = blackman_window!float(src[i], i, N);
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
                if (apply_window)
                    f = blackman_window(f, i, N);
                dst[i] = f;
            }
            break;
        default:
            throw new Exception(text("not impl: resampling"));
        }
        
        // FFT, this may modify the immediate buffer
        Duration d0 = sw.peek();
        // TODO: fix slice to select up to binsize or whatever, this is just bad
        float[] samples = dst[0..binsize];
        Complex!float frame = analyzer.fftfreq!float(samples, config.sample_rate, targetfreq);
        float mag = magnitude!float(frame);
        Duration d1 = sw.peek();
        
        // Print processed frame info
        if (verbose)
        {
            ReducedDuration rd = ReducedDuration(d1 - d0);
            stderr.writefln("PT = %3d %s, M = %10.1f", rd.base, rd.unit, mag);
        }
        
        // Threshold needs to be set after some time.
        // ALSA software interface (plughw:) might normalize things (better that than
        // having clipping) so wait for a bit before setting threshold.
        if (threshold == 0.0 && d1 >= dur!"seconds"(5))
        {
            // Make sure we have something and not just zero.
            float t = frame.magnitude / 4;
            if (t > 0.0)
            {
                threshold = t;
                if (verbose)
                    stderr.writefln("Th = %.1f", threshold);
            }
        }
        
        // Holding a recording until "record index".
        // When the index hits it, dump the backbuffer.
        if (holding == true && ++reci == REC0)
        {
            string name = dumpname();
            dumpbuffer(name, backbuffer, backbuffer_length, SamplingFormat.f32le,
                backi, config.period_size, AMT, config.sample_rate);
            stderr.writeln("Du = ", name);
            
            // reset record status, allowing the checks for new states again
            holding = false;
        }
        
        // If we're NOT holding for a recording, it's okay to update state.
        if (holding == false)
        {
            // If the magnitude of the analyzed frequency is lower than our
            // threshold, then changing the status means that something happened.
            State newstate = frame.magnitude < threshold ? State.down : State.up;
            
            // It'd be pointless to dump the buffer when the threshold isn't set or
            // when we're already waiting to capture enough data for a dump.
            //
            // So only initiate a recording if (1) a threshold is set, (2) there isn't
            // a recording being held, and (3) the state changed (e.g., up to down).
            if (threshold != 0.0 && holding == false && state != newstate)
            {
                holding = true;
                reci = 0;
                state = newstate;
                if (verbose)
                    writeln("St = ", state);
            }
        }
        
        backi++; // increase slice index
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
