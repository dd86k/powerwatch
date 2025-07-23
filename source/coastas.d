/// Costas Loop
module coastas;

import std.math.constants : PI;
import std.math.trigonometry : cos, sin, atan2;

enum float PI2 = PI * 2;

struct CostasLoop
{
    float freqmin = 0.0;
    float freqmax = 1000.0;
    float frequency = 0.0;  // Current frequency estimate

    float phase = 0.0;      // Current phase of the VCO

    float alpha = 0.05;     // attack aggressiveness
    float loop_gain = 0.0025;
    
    float I_avg = 0.0;
    float Q_avg = 0.0;
    
    void reset()
    {
        this = this.init;
    }
    
    void update(short[] samples, int sample_rate)
    {
        foreach (sample; samples)
            update(sample, sample_rate);
    }
    
    // use PCM S16 sample
    void update(short sample, int sample_rate)
    {
        // most -1.0,1.0: 32768.0
        // full -1.0,1.0: 32767.0
        update(sample / 32768.0f, sample_rate); // Normalize S16 to [-1.0,1.0]
    }
    
    void update(float[] samples, int sample_rate)
    {
        foreach (sample; samples)
            update(sample, sample_rate);
    }
    
    void update(float sample, int sample_rate)
    {
        // Local oscillator signals
        float I = sample * cos(phase);
        float Q = sample * sin(phase);

        // Simple IIR low-pass filter
        I_avg = alpha * I + (1 - alpha) * I_avg;
        Q_avg = alpha * Q + (1 - alpha) * Q_avg;

        // Phase detector (for pure sinusoid)
        //float phase_error = I_avg * Q_avg;
        float phase_error = atan2(Q_avg, I_avg);

        // Frequency control (integral only for demonstration)
        frequency += loop_gain * phase_error;

        // Clamp
        if (frequency < freqmin) frequency = freqmin;
        if (frequency > freqmax) frequency = freqmax;

        // Update phase
        phase += PI2 * frequency / sample_rate;
        if (phase > PI2) phase -= PI2;
        if (phase < 0)   phase += PI2;
    }
}
version (none)
unittest
{
    import std.stdio : writefln;
    import std.math.operations : isClose;
    enum TARGET = 60;    // Hz
    enum RATE   = 44100; // sample rate, Hz

    // CL loop
    CostasLoop cl;
    cl.freqmin   = 58; // minimum frequency
    cl.freqmax   = 62; // maximum frequency
    for (int i = 0; i < RATE * 25; i++)
    {
        // Generate sample with target frequency and sampling rate as PCM S16
        float sample = sin(PI2 * TARGET * i / RATE);
        
        cl.update(sample, RATE);
        
        /*
        if (i % 200 == 0)
            writefln("sample=%4d s=%9f freq=%9f phase=%9f", i, sample, cl.frequency, cl.phase);
        */
    }
    writefln("Estimated frequency (CL) = %.3f Hz", cl.frequency);
    assert(cl.frequency.isClose(TARGET, 0.1), "VCO freq != TARGET");
}