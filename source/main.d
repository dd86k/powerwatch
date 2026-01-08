module main;

import snddrv.asound : Asound, AsoundConfig, SND_PCM_FORMAT_UNKNOWN, AFORMATS;
import std.format : format;
import std.getopt;
import std.stdio;
static import powerwatch;
static import tests;

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
        // We don't need a stack trace for CLI errors
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
        
        // TODO: powerwatch module should take care of the ALSA config, not CLI
        AsoundConfig config = AsoundConfig(
            opts.rate,   // rate
            1,              // channels
            //opts.rate,   // period/bin size
            opts.binsize,   // period/bin size
            SND_PCM_FORMAT_UNKNOWN // format
        );
        
        powerwatch.listen(opts.device, config, opts.target, opts.binsize, opts.verbose);
        break;
    case "analyze": // analyze sound file (or do "analyze-json"/--json)
        if (args.length < 2)
        {
            throw new Exception("Need audio file");
        }
        
        powerwatch.analyze(args[1], opts.binsize, opts.target);
        break;
    case "dump": // dump wav stats
        if (args.length < 2)
        {
            throw new Exception("Need audio file");
        }
        
        powerwatch.dump(args[1], opts.binsize, opts.target);
        break;
    case "info": // file info
        if (args.length < 2)
        {
            throw new Exception("Need audio file");
        }
        
        powerwatch.info(args[1]);
        break;
    case "test-bench":
        tests.bench(opts.binsize);
        break;
    case "test-write":
        tests.write_waves();
        break;
    case "help": goto Lhelp;
    case "version": CLI_version(); break;
    default:
        stderr.writeln("error: Unknown action: \"", action, "\"");
        return 1;
    }
    
    return 0;
}
