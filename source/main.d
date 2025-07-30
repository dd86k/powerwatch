module main;

import core.math : sqrt;
import std.complex : Complex;
import std.concurrency;
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

// thread 0 wants info
struct MsgQuit
{
    
}
// thread 0 wants to save buffer
struct MsgSave
{
    
}
// 
struct MsgDone
{
    
}

alias Sample = short; // Sampling type (short=S16)

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
void dumpbuffer(string path, Sample[] buffer,
    size_t periodsize, size_t periodcounts, size_t periodidx,
    int sample_rate)
{
    static if (is(Sample == short))
        enum FORMAT = WavFormat.pcm;
    else static if (is(Sample == float))
        enum FORMAT = WavFormat.ieee_float;
    else
        static assert(0, "format");
    enum CHANNELS = 1;
    
    // HACK: Fixes last "slice" being saved first
    ++periodidx;
    
    scope WavWriter writer = new WavWriter(path);
    writer.setinfo(FORMAT, CHANNELS, sample_rate, buffer.length);
    for (size_t t; t < periodcounts; t++, periodidx++)
    {
        if (periodidx >= periodcounts) periodidx = 0; // round-trip
        size_t z = periodidx * periodsize;
        writer.write(buffer[z .. z + periodsize]);
    }
}

enum State : ubyte { down, up }

// TODO: New thread for analysis
//       Copy received buffer to other thread
// NOTE: spawn template can't deal with optional params
void thread_listen(Tid parent, string device, AsoundConfig config, int targetfreq, int binsize,
    bool verbose)
{
    static if (is(Sample == short))
        enum FORMAT = SND_PCM_FORMAT_S16_LE;
    else static if (is(Sample == float))
        enum FORMAT = SND_PCM_FORMAT_FLOAT_LE;
    else
        static assert(0, "format");
    enum AMT = 20;  // number of record "slices" for backbuffer.
                    // typically, a "slice" is an amount of frames, containing samples.
                    // 32K * 20 = 655360 samples
                    // 655360 @ 48000 s/s = ~13.65 secs
    enum REC0 = AMT / 2;    // record after this many "slices" have passed.
                            // the event should be around the middle
    try
    {
        // Setup alsa stuff
        scope Asound alsa = new Asound();
        
        // Auto detect channels.
        // If sw (plughw), set channels to one. Otherwise, if hw, autodetect.
        // channels: Real number of channels from listen interface
        // config.channels: Only for setting up listen interface
        bool sw_audio = device.startsWith("plughw:");
        uint channels;
        if (sw_audio)
        {
            config.channels = channels = 1;
        }
        else
        {
            channels = alsa.getChannelsForDevice(device);
            if (channels == 0) // shouldn't happen, but just in case
            {
                throw new Exception("ALSA returned zero channels for audio PCM device");
            }
            config.channels = 0; // do not change channels in alsa
        }
        
        // Automatically select format depending on compile type
        config.format = FORMAT;
        
        // HACK: Make it easier to perform FFT since class Fft only takes base-2 lengths
        config.period_size = binsize * channels;
        
        // TODO: Select 32-bit IEEE floats over S16
        
        // Backbuffer setup
        Sample[] backbuffer = new Sample[config.period_size * AMT]; // already zero'd
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
            stderr.writeln("Listening through ", device, "...");
            stderr.writeln("Ch = ", channels);
            stderr.writeln("Fm = ", FORMAT == SND_PCM_FORMAT_S16_LE ? "S16_LE" : "IEEE_F32");
            stderr.writeln("Ta = ", targetfreq);
            stderr.writeln("Bs = ", binsize);
            stderr.writeln("Sr = ", config.sample_rate);
            stderr.writefln("Re = %f", freqresolution(binsize, config.sample_rate));
        }
        
        size_t   aframes = channels * config.period_size;
        Sample[] abuffer = new Sample[aframes]; // ALSA immediate buffer, all channels
        
        StopWatch sw;
        sw.start();
        alsa.listen(device, config, abuffer.ptr, (void *buffer, size_t nframes, ref int astatus) {
            // Copy period time to back buffer
            import core.stdc.string : memcpy, memset;
            if (backi >= AMT) backi = 0; // round-trip
            // Only same samples from the first channel
            if (channels > 1)
            {
                Sample *p = cast(Sample*)buffer;
                for (size_t i; i < nframes; i++)
                    p[i] = p[i * channels];
            }
            short[] samples = (cast(Sample*)buffer)[0..nframes];
            
            // Copy immediate buffer into back buffer (assuming mono-channel)
            memcpy( // Copy one "slice"
                // To slice of buffer
                backbuffer.ptr + (backi * config.period_size),
                // From samples we got
                buffer,
                // Copy period size (slice) worth
                nframes * Sample.sizeof
            );
            
            // Get status from parent thread
            // This is a suboptimal way to do polling
            // TODO: Fuse MsgQuit/MsgSave together to reduce on "polling" overhead
            static immutable Duration polldur = dur!"msecs"(1);
            if (receiveTimeout(polldur, (MsgQuit mq) {}))
            {
                astatus = 0;
                return;
            }
            receiveTimeout(polldur, (MsgSave ms) {
                string name = dumpname();
                dumpbuffer(name, backbuffer, config.period_size, AMT, backi, config.sample_rate);
                if (verbose)
                    stderr.writeln("Du = ", name);
                send(parent, MsgDone());
            });
            
            // FFT, this may modify the immediate buffer
            Duration d0 = sw.peek();
            ResultFrame frame = analyzer.fft(samples, config.sample_rate, targetfreq);
            Duration d1 = sw.peek();
            ReducedDur rd = reduceDuration(d1 - d0);
            
            // print info
            if (verbose)
            {
                stderr.writefln("PT = %3d %s, M = %10.1f",
                    rd.t, rd.unit, frame.magnitude);
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
                dumpbuffer(name, backbuffer, config.period_size, AMT, backi, config.sample_rate);
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
            
            backi++;
        });
    }
    catch (Exception ex)
    {
        stderr.writeln("!! EXCEPTION: ", ex);
    }
    
    send(parent, MsgQuit());
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
    CLIOptions cliopts;
    GetoptResult goptres = void;
    try goptres = getopt(args, config.caseSensitive,
        "binsize",   MSG_binsize, &cliopts.binsize,
        "target",    MSG_target, &cliopts.target,
        "rate",      MSG_rate, &cliopts.rate,
        "device",    "Device to listen from (required for 'listen')", &cliopts.device,
        "V|verbose", "Be verbose", &cliopts.verbose,
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
        struct AFormat
        {
            int format;
            string name;
        }
        static immutable AFormat[] AFORMATS = [
            { SND_PCM_FORMAT_S16_LE, "S16_LE" },
            { SND_PCM_FORMAT_S16_BE, "S16_BE" },
            { SND_PCM_FORMAT_U16_LE, "U16_LE" },
            { SND_PCM_FORMAT_U16_BE, "U16_BE" },
            { SND_PCM_FORMAT_S24_LE, "S24_LE" },
            { SND_PCM_FORMAT_S24_BE, "S24_BE" },
            { SND_PCM_FORMAT_U24_LE, "U24_LE" },
            { SND_PCM_FORMAT_U24_BE, "U24_BE" },
            { SND_PCM_FORMAT_S32_LE, "S32_LE" },
            { SND_PCM_FORMAT_S32_BE, "S32_BE" },
            { SND_PCM_FORMAT_U32_LE, "U32_LE" },
            { SND_PCM_FORMAT_U32_BE, "U32_BE" },
            { SND_PCM_FORMAT_FLOAT_LE, "FLOAT_LE" },
            { SND_PCM_FORMAT_FLOAT_BE, "FLOAT_BE" },
            { SND_PCM_FORMAT_FLOAT64_LE, "FLOAT64_LE" },
            { SND_PCM_FORMAT_FLOAT64_BE, "FLOAT64_BE" },
        ];
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
            try foreach (fmt; AFORMATS)
            {
                if (alsa.samplingFormatAvailableForDevice(dev.name, fmt.format))
                {
                    if (p++) write(", ");
                    write(fmt.name);
                }
            }
            catch (Exception ex)
            {
                
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
        if (!cliopts.device)
        {
            throw new Exception("Need audio interface");
        }
        
        AsoundConfig config = AsoundConfig(cliopts.rate, 1, cliopts.rate);
        Tid tid_listener =
            spawn(&thread_listen, thisTid,
                cliopts.device, config, cliopts.target, cliopts.binsize,
                cliopts.verbose);
        
        import std.string : stripRight, split;
    Lread:
        string[] r = readln().stripRight().split(' ');
        if (r.length == 0)
            goto Lread;
        switch (r[0]) {
        case "q", "quit":
            send(tid_listener, MsgQuit());
            receiveTimeout(dur!"seconds"(3), (MsgQuit q) {});
            return 0;
        case "w", "write":
            send(tid_listener, MsgSave());
            receive(
                (MsgDone md) {}
            );
            break;
        default:
        }
        goto Lread;
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
        scope FreqAnalyzer analyzer = new FreqAnalyzer(cliopts.binsize);
        bool warning_cutoff = false;
        float timerate = cast(float)cliopts.binsize/rate; // time rate
        float time = timerate / 2;
        float threshold = 0.0;
        foreach (s; samples.chunks(cliopts.binsize))
        {
            if (s.length != cliopts.binsize)
                break;
            
            ResultFrame frame = analyzer.fft(s, rate, cliopts.target);
            
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
        CostasLoop cl = CostasLoop(cliopts.target - 0.5, cliopts.target + 0.5);
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
        
        scope FreqAnalyzer analyzer = new FreqAnalyzer(cliopts.binsize);
        float timerate = cast(float)cliopts.binsize/rate; // time rate
        float time = 0.0;
        foreach (s; samples.chunks(cliopts.binsize))
        {
            if (s.length != cliopts.binsize)
                break;
            ResultFrame frame = analyzer.fft(s, rate, cliopts.target);
            float t2 = time+timerate;
            with (frame)
            writefln(" %5d Hz: T=%8.3f-%8.3f, Mg=%10.0f, Ph=%9f", cliopts.target, time, t2, magnitude, phase);
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
        
        scope FreqAnalyzer analyzer = new FreqAnalyzer(cliopts.binsize);
        
        StopWatch sw;
        sw.start();
        foreach (s; samples.chunks(cliopts.binsize))
        {
            if (s.length != cliopts.binsize)
                break;
            analyzer.fft(s, RATE, TARGET, false);
        }
        sw.stop();
        Duration fftdur = sw.peek();
        
        sw.reset();
        sw.start();
        foreach (s; samples.chunks(cliopts.binsize))
        {
            if (s.length != cliopts.binsize)
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
        short[] samples = new short[RATE * SECS]; // S16 PCM
        for (size_t i; i < samples.length; i++)
        {
            samples[i] = cast(short)((short.max / 2) * sin(2 * PI * i * TARGET / RATE));
        }
        
        dumpbuffer("test-write.wav", samples, RATE, SECS, 0, RATE); // or have "test-dump" for this
        /*
        scope WavWriter writer = new WavWriter("test-write.wav");
        writer.setinfo(WavFormat.pcm, 1, RATE, samples.length);
        writer.write(samples);
        */
        break;
    case "help": goto Lhelp;
    case "version": CLI_version(); break;
    default:
        stderr.writeln("error: Unknown action: \"", action, "\"");
        return 1;
    }
    
    return 0;
}
