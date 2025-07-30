/// ALSA driver
module snddrv.asound;

version (linux):

pragma(lib, "asound");

import libasound.ver;
import libasound.control;
import libasound.error;
import libasound.pcm;
import core.stdc.errno;
import std.string : fromStringz, toStringz;

// libasound-d is incomplete
enum SND_PCM_STREAM_CAPTURE             = _snd_pcm_stream.SND_PCM_STREAM_CAPTURE;
enum SND_PCM_ACCESS_MMAP_INTERLEAVED    = _snd_pcm_access.SND_PCM_ACCESS_MMAP_INTERLEAVED;
enum SND_PCM_ACCESS_MMAP_NONINTERLEAVED = _snd_pcm_access.SND_PCM_ACCESS_MMAP_NONINTERLEAVED;
enum SND_PCM_ACCESS_MMAP_COMPLEX        = _snd_pcm_access.SND_PCM_ACCESS_MMAP_COMPLEX;
enum SND_PCM_ACCESS_RW_INTERLEAVED      = _snd_pcm_access.SND_PCM_ACCESS_RW_INTERLEAVED;
enum SND_PCM_ACCESS_RW_NONINTERLEAVED   = _snd_pcm_access.SND_PCM_ACCESS_RW_NONINTERLEAVED;
enum SND_PCM_FORMAT_S8          = _snd_pcm_format.SND_PCM_FORMAT_S8;
enum SND_PCM_FORMAT_U8          = _snd_pcm_format.SND_PCM_FORMAT_U8;
enum SND_PCM_FORMAT_U16_LE      = _snd_pcm_format.SND_PCM_FORMAT_U16_LE;
enum SND_PCM_FORMAT_U16_BE      = _snd_pcm_format.SND_PCM_FORMAT_U16_BE;
enum SND_PCM_FORMAT_S16_LE      = _snd_pcm_format.SND_PCM_FORMAT_S16_LE;
enum SND_PCM_FORMAT_S16_BE      = _snd_pcm_format.SND_PCM_FORMAT_S16_BE;
enum SND_PCM_FORMAT_U24_LE      = _snd_pcm_format.SND_PCM_FORMAT_U24_LE;
enum SND_PCM_FORMAT_U24_BE      = _snd_pcm_format.SND_PCM_FORMAT_U24_BE;
enum SND_PCM_FORMAT_S24_LE      = _snd_pcm_format.SND_PCM_FORMAT_S24_LE;
enum SND_PCM_FORMAT_S24_BE      = _snd_pcm_format.SND_PCM_FORMAT_S24_BE;
enum SND_PCM_FORMAT_U32_LE      = _snd_pcm_format.SND_PCM_FORMAT_U32_LE;
enum SND_PCM_FORMAT_U32_BE      = _snd_pcm_format.SND_PCM_FORMAT_U32_BE;
enum SND_PCM_FORMAT_S32_LE      = _snd_pcm_format.SND_PCM_FORMAT_S32_LE;
enum SND_PCM_FORMAT_S32_BE      = _snd_pcm_format.SND_PCM_FORMAT_S32_BE;
enum SND_PCM_FORMAT_FLOAT_LE    = _snd_pcm_format.SND_PCM_FORMAT_FLOAT_LE;
enum SND_PCM_FORMAT_FLOAT_BE    = _snd_pcm_format.SND_PCM_FORMAT_FLOAT_BE;
enum SND_PCM_FORMAT_FLOAT64_LE  = _snd_pcm_format.SND_PCM_FORMAT_FLOAT64_LE;
enum SND_PCM_FORMAT_FLOAT64_BE  = _snd_pcm_format.SND_PCM_FORMAT_FLOAT64_BE;
extern (C)
{
    int snd_ctl_pcm_next_device(snd_ctl_t *ctl, int *device);
    int snd_ctl_pcm_info(snd_ctl_t *ctl, snd_pcm_info_t *info);
    int snd_ctl_pcm_prefer_subdevice(snd_ctl_t *ctl, int subdev);
}

// 
class AsoundException : Exception
{
    this(int errcode, string prefix = null,
        string _file = __FILE__, int _line = __LINE__)
    {
        import std.conv : text;
        code = errcode;
        string asoundmsg = cast(string)fromStringz(snd_strerror(errcode));
        if (prefix)
            super(text(prefix, ": ", asoundmsg), _file, _line);
        else
            super(asoundmsg, _file, _line);
    }
    
    /// libasound error code.
    int code;
}

// 
struct AsoundDevice
{
    string id;
    string driver;
    string name;
    string longname;
    string mixername;
    string components;
    string[] pcm_inputs;
}

struct AsoundPCMDev
{
    string   name;
    string[] descriptions;
    //uint     channels;
}

// Capture or playback configuration
struct AsoundConfig
{
    int sample_rate = 48000;
    // Should be selecting a channel...
    uint channels    = 1;
    int period_size = 48000; // notify every N frames
    int format      = SND_PCM_FORMAT_S16_LE;
}

// 
class Asound
{
    this()
    {
        snd_lib_error_set_handler(null);
        snd_lib_error_set_local(null);
    }
    
    AsoundPCMDev[] listPCMDevices(int stream = SND_PCM_STREAM_CAPTURE)
    {
        import core.stdc.string : strcmp;
        import core.stdc.stdlib : free;
        
        // NOTE: This is really the way aplay(1) does it
        void **hints;
        int error = snd_device_name_hint(-1, "pcm", &hints);
        if (error < 0)
            throw new AsoundException(error, "Failed to get device name hints");
        
        AsoundPCMDev[] devs;
        
        char *desc1;
        void **n = hints;
        const(char) *filter = stream == SND_PCM_STREAM_CAPTURE ? "Input" : "Output";
        while (*n != null)
        {
            char *name = snd_device_name_get_hint(*n, "NAME");
            char *desc = snd_device_name_get_hint(*n, "DESC");
            char *io = snd_device_name_get_hint(*n, "IOID");
            if (io != null && strcmp(io, filter) != 0)
                goto Lend;
            
            import std.string : split;
            devs ~= AsoundPCMDev(
                fromStringz( name ).idup,
                // Can have multiple descriptions separated by newlines
                fromStringz( desc ).idup.split('\n')
            );
            
            /*
            printf("%s\n", name);
            if ((desc1 = desc) != null)
            {
                printf("    ");
                while (*desc1)
                {
                    if (*desc1 == '\n')
                        printf("\n    ");
                    else
                        putchar(*desc1);
                    desc1++;
                }
                putchar('\n');
            }
            */
            
        Lend:
            if (name != null) free(name);
            if (desc != null) free(desc);
            if (io != null)   free(io);
            n++;
        }
        
        snd_device_name_free_hint(hints);
        
        return devs;
    }
    
    AsoundDevice[] listInputDevices()
    {
        snd_ctl_t *handle;
        snd_ctl_card_info_t *info;
        snd_pcm_info_t *pcm_info;
        
        //snd_ctl_card_info_alloca(&info);
        //snd_pcm_info_alloca(&pcm_info);
        assert(snd_ctl_card_info_malloc(&info) == 0, "snd_ctl_card_info_malloc failed");
        scope(exit) snd_ctl_card_info_free(info);
        assert(snd_pcm_info_malloc(&pcm_info) == 0, "snd_pcm_info_malloc failed");
        scope(exit) snd_pcm_info_free(pcm_info);
        
        AsoundDevice[] devices;
        int err;
        int card = -1;
        while (snd_card_next(&card) >= 0 && card >= 0)
        {
            import core.stdc.stdio : snprintf;
            char[32] name;
            snprintf(name.ptr, name.sizeof, "hw:%d", card);

            // Open the control interface for the card
            if ((err = snd_ctl_open(&handle, name.ptr, 0)) < 0)
            {
                // If the card does not exist, continue to the next
                if (err == -ENOENT)
                    continue;
                throw new AsoundException(err);
            }
            scope(exit) snd_ctl_close(handle);
            
            // Get card information
            if ((err = snd_ctl_card_info(handle, info)) < 0)
            {
                throw new AsoundException(err);
            }
            // Enumerate PCM devices
            int device = -1;
            while (true)
            {
                err = snd_ctl_pcm_next_device(handle, &device);
                if (err < 0)
                {
                    //fprintf(stderr, "snd_ctl_pcm_next_device failed: %s\n", snd_strerror(err));
                    break;
                }
                if (device < 0)
                {
                    break; // No more devices
                }

                // Get PCM info
                snd_pcm_info_set_device(pcm_info, device);
                snd_pcm_info_set_subdevice(pcm_info, 0);
                snd_pcm_info_set_stream(pcm_info, SND_PCM_STREAM_CAPTURE); // Input stream

                if ((err = snd_ctl_pcm_info(handle, pcm_info)) < 0)
                    continue;

                // Print card information
                //printf("Card %d: %s [%s]\n", card, snd_ctl_card_info_get_id(info), snd_ctl_card_info_get_name(info));
                AsoundDevice dev = AsoundDevice(
                    cast(string)fromStringz(snd_ctl_card_info_get_id(info)).idup,
                    cast(string)fromStringz(snd_ctl_card_info_get_driver(info)).idup,
                    cast(string)fromStringz(snd_ctl_card_info_get_name(info)).idup,
                    cast(string)fromStringz(snd_ctl_card_info_get_longname(info)).idup,
                    cast(string)fromStringz(snd_ctl_card_info_get_mixername(info)).idup,
                    cast(string)fromStringz(snd_ctl_card_info_get_components(info)).idup
                );
            
                
                dev.pcm_inputs ~= cast(string)fromStringz(snd_pcm_info_get_name(pcm_info)).idup;
            }
            
            //devices ~= dev;
        }
        
        return devices;
    }
    
    bool samplingFormatAvailableForDevice(string device, int fmt, int stream = SND_PCM_STREAM_CAPTURE)
    {
        if (device is null)
            throw new Exception("Device was not provided");
        
        // Open the sound device in capture mode
        // Default is "default"
        snd_pcm_t *handle;
        int error = snd_pcm_open(&handle, toStringz( device ), cast(_snd_pcm_stream)stream, 0);
        if (error < 0)
            throw new AsoundException(error);
        scope(exit) snd_pcm_close(handle);
        
        snd_pcm_hw_params_t *hw_params;
        if ((error = snd_pcm_hw_params_malloc(&hw_params)) < 0)
            throw new AsoundException(error, "Failed to allocate HW params");
        scope(exit) snd_pcm_hw_params_free(hw_params);
        if ((error = snd_pcm_hw_params_any(handle, hw_params)) < 0)
            throw new AsoundException(error, "Failed to retrieve HW params");
        
        return snd_pcm_hw_params_test_format(handle, hw_params, cast(_snd_pcm_format)fmt) >= 0;
    }
    
    uint getChannelsForDevice(string device, int stream = SND_PCM_STREAM_CAPTURE)
    {
        if (device is null)
            throw new Exception("Device was not provided");
        
        // Open the sound device in capture mode
        // Default is "default"
        snd_pcm_t *handle;
        int error = snd_pcm_open(&handle, toStringz( device ), cast(_snd_pcm_stream)stream, 0);
        if (error < 0)
            throw new AsoundException(error);
        scope(exit) snd_pcm_close(handle);
        
        snd_pcm_hw_params_t *hw_params;
        if ((error = snd_pcm_hw_params_malloc(&hw_params)) < 0)
            throw new AsoundException(error, "Failed to allocate HW params");
        scope(exit) snd_pcm_hw_params_free(hw_params);
        if ((error = snd_pcm_hw_params_any(handle, hw_params)) < 0)
            throw new AsoundException(error, "Failed to retrieve HW params");
        
        uint chans;
        if ((error = snd_pcm_hw_params_get_channels(hw_params, &chans)) < 0)
            throw new AsoundException(error);
        
        return chans;
    }
    
    AsoundDevice[] listDevices()
    {
        snd_ctl_t *handle;
        snd_ctl_card_info_t *info;
        snd_pcm_info_t *pcm_info;
        
        //snd_ctl_card_info_alloca(&info);
        //snd_pcm_info_alloca(&pcm_info);
        assert(snd_ctl_card_info_malloc(&info) == 0, "snd_ctl_card_info_malloc failed");
        scope(exit) snd_ctl_card_info_free(info);
        assert(snd_pcm_info_malloc(&pcm_info) == 0, "snd_pcm_info_malloc failed");
        scope(exit) snd_pcm_info_free(pcm_info);
        
        AsoundDevice[] devices;
        int err;
        int card = -1;
        while (snd_card_next(&card) >= 0 && card >= 0)
        {
            import core.stdc.stdio : snprintf;
            char[32] name;
            snprintf(name.ptr, name.sizeof, "hw:%d", card);

            // Open the control interface for the card
            if ((err = snd_ctl_open(&handle, name.ptr, 0)) < 0)
            {
                // If the card does not exist, continue to the next
                if (err == -ENOENT)
                    continue;
                throw new AsoundException(err);
            }
            scope(exit) snd_ctl_close(handle);
            
            // Get card information
            if ((err = snd_ctl_card_info(handle, info)) < 0)
            {
                throw new AsoundException(err);
            }

            // Print card information
            //printf("Card %d: %s [%s]\n", card, snd_ctl_card_info_get_id(info), snd_ctl_card_info_get_name(info));
            AsoundDevice dev = AsoundDevice(
                cast(string)fromStringz(snd_ctl_card_info_get_id(info)).idup,
                cast(string)fromStringz(snd_ctl_card_info_get_driver(info)).idup,
                cast(string)fromStringz(snd_ctl_card_info_get_name(info)).idup,
                cast(string)fromStringz(snd_ctl_card_info_get_longname(info)).idup,
                cast(string)fromStringz(snd_ctl_card_info_get_mixername(info)).idup,
                cast(string)fromStringz(snd_ctl_card_info_get_components(info)).idup
            );
            
            // Enumerate PCM devices
            int device = -1;
            while (true)
            {
                err = snd_ctl_pcm_next_device(handle, &device);
                if (err < 0)
                {
                    //fprintf(stderr, "snd_ctl_pcm_next_device failed: %s\n", snd_strerror(err));
                    break;
                }
                if (device < 0)
                {
                    break; // No more devices
                }

                // Get PCM info
                snd_pcm_info_set_device(pcm_info, device);
                snd_pcm_info_set_subdevice(pcm_info, 0);
                snd_pcm_info_set_stream(pcm_info, SND_PCM_STREAM_CAPTURE); // Input stream

                if ((err = snd_ctl_pcm_info(handle, pcm_info)) < 0)
                {
                    //printf("  Input Device %d: %s\n", device, snd_pcm_info_get_name(pcm_info));
                    continue;
                }
                dev.pcm_inputs ~= cast(string)fromStringz(snd_pcm_info_get_name(pcm_info)).idup;
            }
            
            devices ~= dev;
        }
        
        return devices;
    }
    
    void listen(string device, AsoundConfig config, void *buffer,
        void delegate(void *buffer, size_t nframes, ref int status) cb)
    {
        if (device is null)
            throw new Exception("Device was not provided");
        if (buffer == null)
            throw new Exception("Buffer is null");
        if (cb is null)
            throw new Exception("Callback was not provided");
        
        // Open the sound device in capture mode
        // Default is "default"
        snd_pcm_t *handle;
        int error = snd_pcm_open(&handle, toStringz( device ), SND_PCM_STREAM_CAPTURE, 0);
        if (error < 0)
            throw new AsoundException(error, "Failed to open device");
        scope(exit) snd_pcm_close(handle);
        
        // Setup sw
        /*
        snd_pcm_sw_params_t *sw_params;
        if ((error = snd_pcm_sw_params_malloc(&sw_params)) < 0)
            throw new AsoundException(error, "Could not allocate SW params");
        scope(exit) snd_pcm_sw_params_free(sw_params);
        if ((error = snd_pcm_sw_params_current(handle, sw_params)) < 0)
            throw new AsoundException(error, "Failed to retrieve SW params");
        */
        
        // Setup hw
        snd_pcm_hw_params_t *hw_params;
        if ((error = snd_pcm_hw_params_malloc(&hw_params)) < 0)
            throw new AsoundException(error, "Could not allocate HW params");
        scope(exit) snd_pcm_hw_params_free(hw_params);
        if (snd_pcm_hw_params_any(handle, hw_params) < 0)
            throw new Exception("Failed to retrieve HW params");
        
        // Setup ALSA internal parameters
        if ((error = snd_pcm_hw_params_set_access(handle, hw_params, SND_PCM_ACCESS_RW_INTERLEAVED)) < 0)
            throw new AsoundException(error, "Can't set PCM acces to interleaved mode");
        if ((error = snd_pcm_hw_params_set_format(handle, hw_params, cast(_snd_pcm_format)config.format)) < 0)
            throw new AsoundException(error, "Can't set PCM format");
        if (config.channels != 0 && // avoid setting when channel count left unspecified
            (error = snd_pcm_hw_params_set_channels(handle, hw_params, config.channels)) < 0)
            throw new AsoundException(error, "Can't set PCM channel count");
        /*
        uint channels;
        if ((error = snd_pcm_hw_params_get_channels(hw_params, &channels)) < 0)
            throw new AsoundException(error, "Can't get PCM channel count");
        */
        uint sample_rate = config.sample_rate; // samples/s
        if ((error = snd_pcm_hw_params_set_rate_near(handle, hw_params, &sample_rate, null)) < 0)
            throw new AsoundException(error, "Can't set number rate");
        snd_pcm_uframes_t period_size = config.period_size; // ulong: get notified every N frames
        if ((error = snd_pcm_hw_params_set_period_size_near(handle, hw_params, &period_size, null)) < 0)
            throw new AsoundException(error, "Can't set period size");

        // Push HW params
        if ((error = snd_pcm_hw_params(handle, hw_params)) < 0)
            throw new AsoundException(error, "Failed to setup hw parameters");
        
        int status = 1;
        while (status)
        {
            snd_pcm_sframes_t readn = snd_pcm_readi(handle, buffer, period_size);
            if (readn < 0)
            {
                // Recover the ALSA internal state if an error occurs
                enum SND_ERR_SILENCE = 0; // do not print
                error = cast(int)readn;
                int recover = snd_pcm_recover(handle, error, SND_ERR_SILENCE);
                if (recover < 0)
                    throw new AsoundException(error, "Failed to recover state");
            }
            if (readn == 0)
                continue;
            //short[] samples = (cast(short*)buffer)[0..readn * channels];
            cb(buffer, cast(size_t)readn, status);
        }
    }
}
