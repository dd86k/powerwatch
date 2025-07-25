module main;

import std.stdio;
import std.getopt;
import std.complex : Complex;
import core.math : sqrt;
import std.math.constants : PI;
import std.math.trigonometry : cos, sin, atan2;
import std.concurrency;
import std.datetime : DateTime, Duration, dur;
import std.datetime.stopwatch : StopWatch;
import std.datetime.systime : Clock, SysTime;
import coastas;
import wav;
import freq;
import snddrv.asound;

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

// TODO: Interface listening
//       "Learn" the current peak after 5 seconds, divide by 2, set as new threshold
//       Warn if clipping occurs (e.g., in S16, if PCM values reach short.min/max)

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
void dumpbuffer(string path, short[] buffer,
    size_t periodsize, size_t periodcounts, size_t periodidx,
    int sample_rate)
{
    enum CHANNELS = 1;
    scope WavWriter writer = new WavWriter(path);
    writer.setinfo(WavFormat.pcm, CHANNELS, sample_rate, buffer.length);
    for (size_t t, i = periodidx; t < periodcounts; t++, i++)
    {
        if (i >= periodcounts) i = 0; // round-trip
        size_t z = i * periodsize;
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
    try
    {
        scope Asound alsa = new Asound();
    
        // TODO: channel autodetection
        // TODO: Select 32-bit IEEE floats over S16
        
        // HACK: Make it easier to perform FFT since class Fft only takes base-2 lengths
        config.period_size = binsize;
        
        // To reduce manipulation errors, make a structure
        enum AMT = 40;  // number of record "slices". 32K @ 48000 samp/s * 40 = 6.827 s
                        // 32K (FFT) * 40 = 1 310 720 samples
                        // 1310720 samples / 96000 samples/s = ~13.65(3) seconds
        short[] backbuffer = new short[config.period_size * AMT]; // S16
        backbuffer[] = 0;
        size_t backi; /// backbuffer "slice" index
        bool holding; /// If true, we're holding for a recording soon
        State state = State.up; /// Last known state, assume up
        enum REC0 = AMT / 2; // record after this many "slices"
        size_t reci; /// Record/Hold index, up until REC0
        
        // HACK: Recoding notification matching binsize for easier analysis
        scope FreqAnalyzer analyzer = new FreqAnalyzer(binsize);
        
        //CostasLoop cl = CostasLoop(targetfreq - .5, targetfreq + .5);
        short[] buffer =  new short[config.period_size]; // for alsa
        float threshold = 0.0;
        
        if (verbose)
        {
            stderr.writeln("Listening through ", device, "...");
            stderr.writeln("Ta = ", targetfreq);
            stderr.writeln("Bs = ", binsize);
            stderr.writeln("Sr = ", config.sample_rate);
            stderr.writefln("Re = %f", freqresolution(binsize, config.sample_rate));
        }
        StopWatch sw;
        sw.start();
        alsa.listen(device, config, buffer.ptr, (short[] samples, ref int status) {
            
            // TODO: Copy buffer anew for analysis to avoid modifying backbuffer
            
            // copy period to back buffer
            import core.stdc.string : memcpy;
            if (backi >= AMT) backi = 0; // round-trip
            memcpy(
                // To slice of buffer
                backbuffer.ptr + (backi * config.period_size),
                // From samples we got
                samples.ptr,
                // one second worth to match period size
                config.period_size * ushort.sizeof
            );
            
            // estimate frequency (wip)
            /*
            foreach (short samp; samples)
                cl.update(samp, config.sample_rate);
            */
            
            // FFT
            Duration d0 = sw.peek();
            ResultFrame frame = analyzer.fft(samples, config.sample_rate, targetfreq);
            Duration d1 = sw.peek();
            ReducedDur rd = reduceDuration(d1 - d0);
            
            // Get status from parent thread
            // This is a suboptimal way to do polling
            // TODO: Fuse MsgQuit/MsgSave together to reduce on "polling" overhead
            if (receiveTimeout(dur!"msecs"(1), (MsgQuit mq) {}))
            {
                status = 0;
                return;
            }
            receiveTimeout(dur!"msecs"(1), (MsgSave ms) {
                string name = dumpname();
                dumpbuffer(name, backbuffer, config.period_size, AMT, backi, config.sample_rate);
                if (verbose)
                    stderr.writeln("Du = ", name);
                send(parent, MsgDone());
            });
            
            // print info
            if (verbose)
                stderr.writefln("PT = %3d %s, M = %10.1f, P = %10.1f",
                    rd.t, rd.unit,
                    frame.magnitude, frame.phase);
            
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
            }
            
            // Holding a recording until "record index"
            if (holding == true && ++reci == REC0)
            {
                string name = dumpname();
                dumpbuffer(name, backbuffer, config.period_size, AMT, backi, config.sample_rate);
                stderr.writeln("Du = ", name);
                
                // reset record index
                holding = false;
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

struct CLIOptions
{
    /// Bin size.
    // 60 (Hz) * 32K / 48000 (samp/s) = 40.96
    // 50 (Hz) * 32K / 48000 (samp/s) = 34.13(3)
    int binsize = 32768;
    /// Frequency target.
    int target  = 60;
    /// Target sample rate
    int rate    = 48000;
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
void print_version()
{
    import core.stdc.stdlib : exit;
    writeln("Compiled: ", __TIMESTAMP__);
    writeln("Compiler: ", __VENDOR__, " ", DSTRVER!__VERSION__);
    exit(0);
}

int main(string[] args)
{
    CLIOptions cliopts;
    GetoptResult goptres = void;
    try goptres = getopt(args, config.caseSensitive,
        "binsize",   "Set bin size (default=32768)", &cliopts.binsize,
        "target",    "Target frequency in Hertz (default=60)", &cliopts.target,
        "rate",      "Target sample rate for recording (default=48000)", &cliopts.rate,
        "device",    "Device to listen from (required for 'listen')", &cliopts.device,
        "V|verbose", "Be verbose", &cliopts.verbose,
        "version",   "Show version and quit", &print_version);
    catch (Exception ex)
    {
        stderr.writeln("error: ", ex.msg);
        return 1;
    }
    
    if (goptres.helpWanted || args.length <= 1) // only program name
    {
    Lhelp:
        defaultGetoptPrinter("Hum checker\n\nOptions:", goptres.options);
        writeln("\nCommands:");
        writeln("  list ............ List input PCM devices");
        writeln("  list-all ........ List all audio devices");
        writeln("  listen .......... Listen to audio interface (using --device=)");
        writeln("  analyze FILE .... Analyze a sound file");
        writeln("  dump FILE ....... Dump stats of FILE, a sound file");
        writeln("  info FILE ....... Dump information about FILE, a sound file");
        writeln("  test-bench ...... Benchmark functions");
        writeln("  test-write ...... Test the WAV file writer");
        writeln("  help ............ This help page");
        writeln("\nExamples:");
        writeln();
        writeln("  Listen to an interface:");
        writeln("    powerwatch listen --device=plughw:CARD=Generic,DEV=0");
        return 0;
    }
    
    // slice out program name
    args = args[1..$];
    
    // 
    string action = args[0];
    
    switch (action) {
    case "list": // list input-capable devices
        writeln("Input devices (ALSA):");
        foreach (ref dev; new Asound().listPCMDevices())
        {
            writeln(dev.name);
            
            foreach (desc; dev.descriptions)
            {
                writeln("    ", desc);
            }
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
        
        enum CUTOFF = 20000.0f; // cheap
        
        //
        // Cutoff checking
        //
        bool warning_cutoff = false;
        Result result = analyzefft(samples, rate, cliopts.binsize, cliopts.target);
        foreach (frame; result.frames)
        {
            if (warning_cutoff == false)
            {
                if (frame.magnitude < CUTOFF)
                {
                    stderr.writefln("~%7.3f: DOWN", (frame.t0 + frame.t1) / 2);
                    warning_cutoff = true;
                }
            }
            else
            {
                if (frame.magnitude >= CUTOFF)
                {
                    stderr.writefln("~%7.3f: UP", (frame.t0 + frame.t1) / 2);
                    warning_cutoff = false;
                }
            }
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
        
        Result result = analyzefft(samples, rate, cliopts.binsize, cliopts.target);
        foreach (frame; result.frames)
            with (frame)
            writefln(" %5d Hz: T=%8.3f-%8.3f, Mg=%10.0f, Ph=%9f", cliopts.target, t0, t1, magnitude, phase);
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
        
        StopWatch sw;
        sw.start();
        Result fft = analyzefft(samples, RATE, cliopts.binsize, cliopts.target);
        sw.stop();
        Duration fftdur = sw.peek();
        
        sw.reset();
        sw.start();
        Result dft = analyzedft(samples, RATE, cliopts.binsize, cliopts.target);
        sw.stop();
        Duration dftdur = sw.peek();
        
        ReducedDur rdfft = reduceDuration(fftdur);
        ReducedDur rddft = reduceDuration(dftdur);
        writefln("FFT: %3d %s", rdfft.t, rdfft.unit);
        writefln("DFT: %3d %s", rddft.t, rddft.unit);
        
        //CostasLoop clfft = CostasLoop(40, 80);
        float ffthigh = 0.0, fftlow = 0.0;
        foreach (ref frame; fft.frames)
        {
            if (frame.magnitude > ffthigh) ffthigh = frame.magnitude;
            if (frame.magnitude < fftlow)  fftlow  = frame.magnitude;
        }
        //CostasLoop cldft = CostasLoop(40, 80);
        float dfthigh = 0.0, dftlow = 0.0;
        foreach (ref frame; dft.frames)
        {
            if (frame.magnitude > dfthigh) dfthigh = frame.magnitude;
            if (frame.magnitude < dftlow)  dftlow  = frame.magnitude;
        }
        writefln("FFT high= %f  low = %f ", ffthigh, fftlow);
        writefln("DFT high= %f  low = %f ", dfthigh, dftlow);
        
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
        dumpbuffer("test-write.wav", samples, RATE, SECS, 5, RATE);
        /*
        scope WavWriter writer = new WavWriter("test-write.wav");
        writer.setinfo(WavFormat.pcm, 1, RATE, samples.length);
        writer.write(samples);
        */
        break;
    case "help": goto Lhelp;
    default:
        stderr.writeln("error: Unknown action: \"", action, "\"");
        return 1;
    }
    
    return 0;
}
