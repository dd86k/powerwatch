module tests;

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
import powerwatch : ReducedDuration, dumpbuffer, SamplingFormat;

void bench(size_t binsize)
{
    // Better to generate the same wave for both
    enum TARGET = 60;     // Hz
    enum RATE   = 48_000; // Hz
    enum SECS   = 30;     // 30s * 48000hz * float.sizeof = ~5.5 MiB
    float[] samples = new float[RATE * SECS]; // S16 PCM
    for (size_t i; i < samples.length; i++)
        samples[i] = sin(2 * PI * TARGET * i / RATE);
    writefln("SETTINGS: RATE=%d SECS=%d", RATE, SECS);
    
    scope FreqAnalyzer analyzer = new FreqAnalyzer(binsize);
    
    StopWatch sw;
    sw.start();
    foreach (s; samples.chunks(binsize))
    {
        if (s.length != binsize)
            break;
        analyzer.fftfreq(s, RATE, TARGET);
    }
    sw.stop();
    
    Duration fftdur = sw.peek();
    sw.reset();
    
    sw.start();
    foreach (s; samples.chunks(binsize))
    {
        if (s.length != binsize)
            break;
        analyzer.dftfreq(s, RATE, TARGET);
    }
    sw.stop();
    
    Duration dftdur = sw.peek();
    
    writeln("FFT: ", ReducedDuration(fftdur));
    writeln("DFT: ", ReducedDuration(dftdur));
}

void write_waves()
{
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
}
