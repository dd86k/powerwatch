module main;

import std.complex : Complex;
import std.conv : text;
import std.datetime : DateTime, Duration, dur;
import std.datetime.stopwatch : StopWatch;
import std.datetime.systime : Clock, SysTime;
import std.format : format;
import std.getopt;
import std.math.constants : PI;
import std.math.trigonometry : cos, sin, atan2;
import std.range : chunks;
import std.stdio;
import std.string : startsWith;
import coastas;
import freq;
import snddrv.asound;
import wav; // TODO: move to file/wav.d

// TODO: Loop end
//       When the size of the samples doesn't fit bin length (foreach chunks),
//       data should be zero'd instead of just ending the loop.
// TODO: test-listen
//       Listen and dump after AMT (or later dynamic value)

struct ReducedDur
{
    int t;
    string unit;
}
// Simplify time.
ReducedDur reduceDuration(Duration d)
{
    if (d >= dur!"msecs"(1))
        return ReducedDur(cast(int)d.total!"msecs"(), "ms");
    if (d >= dur!"usecs"(1))
        return ReducedDur(cast(int)d.total!"usecs"(), "µs");
    if (d >= dur!"hnsecs"(1))
        return ReducedDur(cast(int)d.total!"hnsecs"(), "hs");
    return ReducedDur(cast(int)d.total!"nsecs"(), "ns");
}

enum SamplingFormat
{
    s16le = SND_PCM_FORMAT_S16_LE,
    s24le = SND_PCM_FORMAT_S24_LE,
    s32le = SND_PCM_FORMAT_S32_LE,
    f32le = SND_PCM_FORMAT_FLOAT_LE,
}
string samplingFormatToString(SamplingFormat fmt)
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
];

deprecated alias Sample = float; // Sampling type (short=S16, float=IEEE 32-bit floats)
alias BinPrecision = float;
alias Bin = Complex!BinPrecision;

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
    writer.setinfo(wfmt, bit, CHANNELS, sample_rate, totalsamples);
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
    config.period_size = binsize * config.channels;
    
    import core.stdc.stdlib : malloc, free;
    // NOTE: Function doesn't return, so don't bother releasing memory
    //       System will reclaim it anyway
    
    // Setup backbuffer, which SHOULD be circular
    // NOTE: Backbuffer MUST be in FLOAT32 sampling format for consistency
    // TODO: Index should be frame index only, not slice
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
                // destination is f32, so just copy
                memcpy(dst, src, nframes * float.sizeof);
            }
            break;
        case SND_PCM_FORMAT_S16_LE, SND_PCM_FORMAT_S16_BE:
            short *src = cast(short*)buffer;
            for (int i; i < N; i++)
            {
                float f = cast(float)src[i] / 32767.0; // S16 -> F32
                if (apply_window)
                    f = blackman_window!float(f, i, N);
                dst[i] = f;
            }
            break;
        default:
            throw new Exception(text("not impl: resampling"));
        }
        
        /+if (apply_window)
        {
            for (int i; i < N; i++)
            {
                float f = cast(float)samples[i] / 32767; // S16 -> F32
                samples[i] = cast(short)(blackman_window!float(f, i, N) * 32767);
            }
        }+/
        
        // FFT, this may modify the immediate buffer
        Duration d0 = sw.peek();
        float[] samples = dst[0..nframes];
        Complex!float frame = analyzer.fftfreq!float(samples, config.sample_rate, targetfreq);
        float mag = magnitude!float(frame);
        Duration d1 = sw.peek();
        
        // Print processed frame info
        if (verbose)
        {
            ReducedDur rd = reduceDuration(d1 - d0);
            stderr.writefln("PT = %3d %s, M = %10.1f", rd.t, rd.unit, mag);
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
            dumpbuffer(name, backbuffer, backbuffer_length, SamplingFormat.s16le,
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

//
// CLI
//

enum DEFAULT_TARGET   = 60;
enum DEFAULT_BINSIZE  = 32 * 1024;
enum DEFAULT_SAMPRATE = 48000;

struct CLIOptions
{
    /// Bin size.
    // 60 (Hz) * 32K / 48000 (samp/s) = 40.96
    // 50 (Hz) * 32K / 48000 (samp/s) = 34.13(3)
    int binsize = DEFAULT_BINSIZE;
    /// Frequency target.
    int target  = DEFAULT_TARGET;
    /// Target sample rate
    int rate    = DEFAULT_SAMPRATE;
    /// PCM device to listen to.
    string device;
    
    /// 
    bool verbose;
}

template DSTRVER(uint ver)
{
    enum DSTRVER =
        cast(char)((ver / 1000) + '0') ~ "." ~
        cast(char)(((ver % 1000) / 100) + '0') ~
        cast(char)(((ver % 100) / 10) + '0') ~
        cast(char)((ver % 10) + '0');
}
void CLI_version()
{
    import core.stdc.stdlib : exit;
    writeln("Compiled  : ", __TIMESTAMP__);
    writeln("Compiler  : ", __VENDOR__, " ", DSTRVER!__VERSION__);
    debug enum DEBUG = true;
    else  enum DEBUG = false;
    writeln("Debug     : ", DEBUG);
    exit(0);
}

immutable string MSG_binsize = format("Set bin size (default=%d)", DEFAULT_BINSIZE);
immutable string MSG_target  = format("Target frequency in Hertz (default=%d)", DEFAULT_TARGET);
immutable string MSG_rate    = format("Target sample rate for recording (default=%d)", DEFAULT_SAMPRATE);

int main(string[] args)
{
    CLIOptions opts;
    GetoptResult goptres = void;
    try goptres = getopt(args, config.caseSensitive,
        "binsize",   MSG_binsize, &opts.binsize,
        "target",    MSG_target, &opts.target,
        "rate",      MSG_rate, &opts.rate,
        "device",    "Device to listen from (required for 'listen')", &opts.device,
        "V|verbose", "Be verbose", &opts.verbose,
        "version",   "Show version and quit", &CLI_version);
    catch (Exception ex)
    {
        stderr.writeln("error: ", ex.msg);
        return 1;
    }
    
    if (goptres.helpWanted || args.length <= 1) // only program name
    {
    Lhelp:
        defaultGetoptPrinter(
            "Hum checker\n"~
            "  Usage: powerwatch ACTION [OPTIONS...] [FILE]\n"~
            "\n"~
            "ACTIONS\n"~
            "  list ............ List input PCM devices (for --device=)\n"~
            "  list-all ........ List all audio devices\n"~
            "  listen .......... Listen to audio interface (using --device=)\n"~
            "  analyze FILE .... Analyze a sound file for cutoffs\n"~
            "  dump FILE ....... Dump magnitude data for a sound file\n"~
            "  info FILE ....... Dump information about a sound file\n"~
            "  test-bench ...... Benchmark functions\n"~
            "  test-write ...... Test the WAV file writer\n"~
            "  help ............ This help page, same as --help\n"~
            "  version ......... Version page, same as --version\n"~
            "\nOPTIONS", goptres.options);
        writeln("\nEXAMPLES");
        writeln("  Listen to an interface with verbose messages:");
        writeln("    powerwatch listen --device=plughw:CARD=Generic,DEV=0 --verbose");
        return 0;
    }
    
    // slice out program name
    args = args[1..$];
    
    // 
    string action = args[0];
    
    switch (action) {
    case "list": // list input-capable devices
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
        break;
    case "list-all": // list all sound interfaces
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
        break;
    case "listen": // to interface
        if (!opts.device)
        {
            throw new Exception("Need audio interface");
        }
        
        AsoundConfig config = AsoundConfig(
            opts.rate,   // rate
            1,              // channels
            opts.rate,   // period size
            SND_PCM_FORMAT_UNKNOWN // format
        );
        
        listen(opts.device, config, opts.target, opts.binsize, opts.verbose);
        break;
    case "analyze": // analyze sound file (or do "analyze-json"/--json)
        if (args.length < 2)
        {
            throw new Exception("Need audio file");
        }
        
        scope WavFile wav = new WavFile().open(args[1]);
        
        int rate = wav.sampleRate();
        
        short[] samples = wav.getData16bit();
        
        //
        // Cutoff checking
        //
        scope FreqAnalyzer analyzer = new FreqAnalyzer(opts.binsize);
        bool warning_cutoff = false;
        float timerate = cast(float)opts.binsize/rate; // time rate
        float time = timerate / 2;
        float threshold = 0.0;
        foreach (s; samples.chunks(opts.binsize))
        {
            if (s.length != opts.binsize)
                break;
            
            ResultFrame frame = analyzer.fft(s, rate, opts.target);
            
            // Take first result as threshold
            if (threshold == 0.0)
            {
                threshold = frame.magnitude / 4;
                // Even if this is still zero, it'll retry next iteration
                // If there are no results, then maybe the signal is too weak
            }
            
            if (warning_cutoff == false)
            {
                if (frame.magnitude < threshold)
                {
                    stderr.writefln("~%7.3f: DOWN", time);
                    warning_cutoff = true;
                }
            }
            else
            {
                if (frame.magnitude >= threshold)
                {
                    stderr.writefln("~%7.3f: UP", time);
                    warning_cutoff = false;
                }
            }
            
            time += timerate;
        }
        
        //
        // Frequency estimation
        //
        CostasLoop cl = CostasLoop(opts.target - 0.5, opts.target + 0.5);
        bool warning_clipping = false;
        foreach (i, sample; samples)
        {
            if (warning_clipping == false)
            {
                if (sample == short.max || sample == short.min)
                {
                    stderr.writeln("warning: clipping detected, result may be inaccurate");
                    warning_clipping = true;
                }
            }
            
            cl.update(sample, rate);
            
            if (i % rate == 0)
            {
                writefln("Estimated VCO Frequency (CL)  = %.3f Hz", cl.frequency);
                cl = CostasLoop(40, 80); // reset
            }
        }
        break;
    case "dump": // dump wav stats
        if (args.length < 2)
        {
            throw new Exception("Need audio file");
        }
        
        scope WavFile wav = new WavFile().open(args[1]);
        int rate = wav.sampleRate();
        short[] samples = wav.getData16bit();
        
        scope FreqAnalyzer analyzer = new FreqAnalyzer(opts.binsize);
        float timerate = cast(float)opts.binsize/rate; // time rate
        float time = 0.0;
        foreach (s; samples.chunks(opts.binsize))
        {
            if (s.length != opts.binsize)
                break;
            ResultFrame frame = analyzer.fft(s, rate, opts.target);
            float t2 = time+timerate;
            with (frame)
            writefln(" %5d Hz: T=%8.3f-%8.3f, Mg=%10.0f, Ph=%9f", opts.target, time, t2, magnitude, phase);
            time = t2;
        }
        break;
    case "info": // file info
        if (args.length < 2)
        {
            throw new Exception("Need audio file");
        }
        
        scope WavFile wav = new WavFile().open(args[1]);
        
        FormatChunk fmtchunk = wav.getFormatChunk();
        
        with (fmtchunk) {
        writeln("format        : ", format);
        writeln("channels      : ", channels);
        writeln("samplerate    : ", samplerate);
        writeln("datarate      : ", datarate);
        writeln("blockalign    : ", blockalign);
        writeln("samplebits    : ", samplebits);
        }
        
        writeln("samples       : ", wav.readallS16().length);
        break;
    case "test-bench":
        import std.datetime.stopwatch : StopWatch, Duration;
        
        // Better to generate the same wave for both
        enum TARGET = 60;     // Hz
        enum RATE   = 48_000; // Hz
        enum SECS   = 30;     // 30s * 48000hz * short.sizeof = ~2.75 MiB
        short[] samples = new short[RATE * SECS]; // S16 PCM
        for (size_t i; i < samples.length; i++)
            samples[i] = cast(short)(short.max * sin(2 * PI * TARGET * i / RATE));
        writefln("SETTINGS: RATE=%d SECS=%d", RATE, SECS);
        
        scope FreqAnalyzer analyzer = new FreqAnalyzer(opts.binsize);
        
        StopWatch sw;
        sw.start();
        foreach (s; samples.chunks(opts.binsize))
        {
            if (s.length != opts.binsize)
                break;
            analyzer.fft(s, RATE, TARGET, false);
        }
        sw.stop();
        Duration fftdur = sw.peek();
        
        sw.reset();
        sw.start();
        foreach (s; samples.chunks(opts.binsize))
        {
            if (s.length != opts.binsize)
                break;
            analyzer.dft(s, RATE, TARGET, false);
        }
        sw.stop();
        Duration dftdur = sw.peek();
        
        ReducedDur rdfft = reduceDuration(fftdur);
        ReducedDur rddft = reduceDuration(dftdur);
        writefln("FFT: %3d %s", rdfft.t, rdfft.unit);
        writefln("DFT: %3d %s", rddft.t, rddft.unit);
        break;
    case "test-write":
        // Better to generate the same wave for both
        enum TARGET = 60;     // Hz
        enum RATE   = 48_000; // samples/s
        enum SECS   = 30;     // 30s * 48000hz * short.sizeof = ~2.75 MiB
        
        // S16
        {
            scope short[] samples_s16 = new short[RATE * SECS];
            for (size_t i; i < samples_s16.length; i++)
            {
                enum AMPLITUDE = (short.max / 2);
                samples_s16[i] = cast(short)(AMPLITUDE * sin(2 * PI * i * TARGET / RATE));
            }
            string name_s16 = "test-write-s16.wav";
            dumpbuffer(name_s16, samples_s16.ptr, samples_s16.length, SamplingFormat.s16le,
                0, RATE, SECS,
                RATE);
            writeln(name_s16, " written");
        }
        
        // S24
        /*{
            scope int[] samples_s24 = new int[RATE * SECS];
            for (size_t i; i < samples_s24.length; i++)
            {
                enum MAX24 = int.max & 0x7fffff;
                enum AMPLITUDE = (MAX24 / 2);
                samples_s24[i] = cast(int)(AMPLITUDE * sin(2 * PI * i * TARGET / RATE)) & 0xffffff;
            }
            string name_s24 = "test-write-s24.wav";
            dumpbuffer(name_s24, samples_s24.ptr, samples_s24.length, SamplingFormat.s24le,
                0, RATE, SECS,
                RATE);
            writeln(name_s24, " written");
        }*/
        
        // S32
        {
            scope int[] samples_s32 = new int[RATE * SECS];
            for (size_t i; i < samples_s32.length; i++)
            {
                enum AMPLITUDE = (int.max / 2);
                samples_s32[i] = cast(int)(AMPLITUDE * sin(2 * PI * i * TARGET / RATE));
            }
            string name_s32 = "test-write-s32.wav";
            dumpbuffer(name_s32, samples_s32.ptr, samples_s32.length, SamplingFormat.s32le,
                0, RATE, SECS,
                RATE);
            writeln(name_s32, " written");
        }
        
        // IEEE F32
        {
            scope float[] samples_f32 = new float[RATE * SECS];
            for (size_t i; i < samples_f32.length; i++)
            {
                enum AMPLITUDE = 0.5; // 1.0 / 2
                samples_f32[i] = AMPLITUDE * sin(2 * PI * i * TARGET / RATE);
            }
            string name_f32 = "test-write-f32.wav";
            dumpbuffer(name_f32, samples_f32.ptr, samples_f32.length, SamplingFormat.f32le,
                0, RATE, SECS,
                RATE);
            writeln(name_f32, " written");
        }
        break;
    case "help": goto Lhelp;
    case "version": CLI_version(); break;
    default:
        stderr.writeln("error: Unknown action: \"", action, "\"");
        return 1;
    }
    
    return 0;
}
