module wav;

import std.stdio : File, SEEK_SET, SEEK_CUR, SEEK_END;

enum WavFormat : ushort
{
     /// Unknown
     unspecified    = 0,
     /// Pulse Code Modulation, usually 16-bit signed
     pcm            = 1,
     /// 32-bit float
     ieee_float     = 3,
     /// alaw
     alaw           = 6, // or 0x0102 for IBM format
     /// µlaw
     mulaw          = 7, // or 0x0101 for IBM format
     /// IBM AVC Adaptive Differential Pulse Code Modulation format
     adpcm          = 0x0103, // ms riff spec
     // Undocumented
     _mp2           = 0x55,
     // Unofficial
     _g729          = 0x83,
     // 
     extensible     = 0xFFFE,
}

struct FormatChunk // fmt_chunk
{
     align(1):
     /// Format.
     WavFormat format;
     /// Number of channels.
     ushort channels;
     /// Sample rate. Blocks per second.
     uint   samplerate;
     /// Data rate in byte/s.
     uint   datarate;
     /// Bytes per frames (NbrChannels * BitsPerSample / 8).
     ushort blockalign;
     /// Bits per sample.
     ushort samplebits;
}

// Structure:
// RIFF signature
// RIFF size
//   Chunk ID
//   Chunk Size
//   Chunk Data...
/// WAV file reader
class WavReader
{
     this(string path)
     {
          openFile(path);
     }
     
     ~this()
     {
          closeFile();
     }
     
     // raw info
     FormatChunk getFormatChunk()
     {
          return fmtchunk;
     }
     
     int sampleRate()
     {
          return fmtchunk.samplerate;
     }
     int channels()
     {
          return fmtchunk.channels;
     }
     size_t sampleSize()
     {
          prepare();
          
          return sample_size;
     }
     
     // In samples
     ulong sampleCount()
     {
          prepare();
          
          return sample_count;
     }
     alias length = sampleCount;
     
     // TODO: seek(frame index)
     // TODO: reset => seek(0)
     
     // Read frames*channels worth of audio (buffer[2] for a single frame for 2 channels).
     // PCM gets normalized to IEEE_FLOAT.
     float[] read(float[] buffer)
     {
          prepare();
          
          // TODO: Read chunks in memory (e.g., ubyte[4096]) for performance reasons
          //       Need interface that automatically reads correct number of frames
          switch (fmtchunk.format) {
          case WavFormat.ieee_float:
               if (fmtchunk.samplebits != 32)
                    throw new Exception(ESUPBIT);
               
               return file.rawRead(buffer);
          case WavFormat.pcm:
               size_t i;
               final switch (fmtchunk.samplebits) {
               case 16:
                    enum NORM = 32768.0;
                    short[1] b16;
                    for (; i < buffer.length; i++)
                    {
                         if (file.rawRead(b16).length == 0)
                         {
                              break;
                         }
                         
                         buffer[i] = b16[0] / NORM;
                    }
                    return buffer[0..i];
               case 24:
                    enum NORM = 8388608.0;
                    ubyte[3] b24; // Assuming LE
                    for (; i < buffer.length; i++)
                    {
                         if (file.rawRead(b24).length < b24.sizeof)
                         {
                              break;
                         }
                         
                         int sample = b24[0] | b24[1] << 8 | b24[2] << 16;
                         if (sample & 0x80_0000)
                              sample |= 0xff00_0000; // sign-extend 24->32 bits
                         buffer[i] = sample / NORM;
                    }
                    return buffer[0..i];
               case 32:
                    enum NORM = 2147483648.0;
                    int[1] b32;
                    for (; i < buffer.length; i++)
                    {
                         if (file.rawRead(b32).length == 0)
                         {
                              break;
                         }
                         
                         buffer[i] = b32[0] / NORM;
                    }
                    return buffer[0..i];
               }
               break;
          default:
               throw new Exception(ENOFMT);
          }
     }
     
     bool eof()
     {
          return file.eof();
     }
     
private:
     // Error messages
     static immutable
     {
          string ETOOSMALL = "File is too small.";
          string EILLSIG   = "File might not be a WAV file.";
          string ESUPFMT   = "Unsupported format.";
          string ESUPBIT   = "Unsupported sample size.";
          string ECHANNELS = "File has more than 1 channel.";
          string EINVCHAN  = "Invalid/weird amount of channels.";
          string ENOFMT    = "Could not find the format chunk.";
          string ENODATA   = "Could not find the data chunk.";
     }
     
     File file;
     _CHBuf cbuffer = void;
     
     /// Chunk metadata ready
     bool ready;
     
     /// 
     ulong sample_count;
     /// Size of one sample in Bytes (channels * bits)
     size_t sample_size;
     
     union
     {
          FormatChunk fmtchunk;
          ubyte[FormatChunk.sizeof] fmtchunk_buffer;
     }
     
     void openFile(string path)
     {
          file.open(path, "rb");
          
          //
          // Find the Format chunk.
          // The first chunk could be RIFF container, and its size is
          // the entire size, which we do not want to skip.
          //
          // WAV files may or may not have the RIFF container,
          // but all of them have a WAVE Format Chunk.
          //
          if (file.rawRead(cbuffer.buffer).length < _CHBuf.sizeof)
          {
               throw new Exception(ETOOSMALL);
          }
          
          // Check first signature
          if (cbuffer.header.id32 == CHUNK_DATA) // data already starts here
          {
               // Only read chunk header
               if (file.rawRead(fmtchunk_buffer).length < fmtchunk_buffer.sizeof)
                    throw new Exception(ETOOSMALL);
               return;
          }
          else if (cbuffer.header.id32 == SIGRIFF) // RIFF signature
          {
               char[4] rifftype = void; // Check RIFF type
               if (file.rawRead(rifftype).length < rifftype.sizeof)
                    throw new Exception(ETOOSMALL);
               if (rifftype != "WAVE")
                    throw new Exception(EILLSIG);
          }
          else
               throw new Exception(EILLSIG);
          
          // Find format chunk, even if it's supposed to be the first one
          enum MAXCNK = 3;
          for (int t; t < MAXCNK; t++)
          {
               // Read chunk signature+size
               if (file.rawRead(cbuffer.buffer).length < _CHBuf.sizeof)
                    throw new Exception(ETOOSMALL);
               
               // If chunk isn't Format ID, skip
               // TODO: Support Chunk Format extensions
               //       If size of chunk is higher than standard, it has extensions
               if (cbuffer.header.id32 != CHUNK_FORMAT)
               {
                    // jump to next chunk, this one isn't the Format chunk
                    file.seek(boundup(cbuffer.header.cksize, 2), SEEK_CUR);
                    continue;
               }
               
               // Chunk too small to represent Format chunk...
               if (cbuffer.header.cksize < FormatChunk.sizeof)
                    throw new Exception(ETOOSMALL);
               
               // Read Format chunk into memory
               if (file.rawRead(fmtchunk_buffer).length < fmtchunk_buffer.sizeof)
                    throw new Exception(ETOOSMALL);
               
               // We have read Format chunk, so seek to next chunk,
               // which SHOULD be data.
               // This ensures we skip extensions because we only (so far),
               // read standard Format Chunk size.
               file.seek(boundup(cbuffer.header.cksize - FormatChunk.sizeof, 2), SEEK_CUR);
               return;
          }
          
          // Can't find "fmt " chunk
          throw new Exception(ENOFMT);
     }
     
     void closeFile()
     {
          if (file.isOpen())
               file.close();
     }
     
     // Assumes header and first chunk were read
     void prepare()
     {
          if (ready)
               return;
          
          // Ensure working with compatible sample bits
          switch (fmtchunk.samplebits) {
          case 8, 16, 24, 32: break;
          default:
               throw new Exception(ESUPBIT);
          }
          // Compatible channels
          if (fmtchunk.channels < 1 || fmtchunk.channels > 8)
               throw new Exception(EINVCHAN);
          
          // Locate DATA chunk
          enum MAXCNK = 6;
          for (int i; i < MAXCNK; i++)
          {
               // likely EOF if can't read chunk header
               if (file.rawRead(cbuffer.buffer).length < _CHBuf.sizeof)
               {
                    break;
               }
               
               // Not data chunk, continue to next chunk
               if (cbuffer.header.id32 != CHUNK_DATA)
               {
                    long loc = boundup(cbuffer.header.cksize, 2);
                    file.seek(loc, SEEK_CUR);
                    continue;
               }
               
               // Found Data Chunk, prepare stuff
          
               sample_size = fmtchunk.channels * (fmtchunk.samplebits/8);
               
               sample_count = cbuffer.header.cksize / sample_size;
               /*data_s16 = new short[samples];
               if (file.rawRead(data_s16).length < samples)
                    throw new Exception(ETOOSMALL);*/
               
               ready = true;
               return;
          }
          
          // Can't find "data" chunk
          throw new Exception(ENODATA);
     }
}

private
long boundup(long x, long s)
{
	size_t mask = s - 1;
	return (x + mask) & (~mask);
}
unittest
{
     assert(boundup(0, 2) == 0);
     assert(boundup(1, 2) == 2);
     assert(boundup(2, 2) == 2);
     assert(boundup(3, 2) == 4);
     assert(boundup(4, 2) == 4);
     assert(boundup(5, 2) == 6);
     assert(boundup(6, 2) == 6);
}

class WavWriter
{
     this(string path)
     {
          file.open(path, "wb");
     }
     
     void writeHeader(WavFormat format, ushort bit,
          ushort channels, uint samplerate, size_t sample_total)
     {
          if (bit == 24)
               throw new Exception("unsupported");
          //ushort filebit = bit;
          //if (bit == 24) filebit = 32; // alignment
          ushort bytesz = bit / 8;
          fmt = FormatChunk(
               format,
               channels,
               samplerate,
               // Data rate in byte/s.
               cast(uint)(samplerate * channels * bytesz),
               // Bytes per frames (NbrChannels * BitsPerSample / 8).
               cast(ushort)(bit * channels),
               // Bits per sample. (uint.sizeof * 8)
               bit); // sample bits (e.g., 16-bit shorts or 32-bit floats)
          
          file.seek(0); // if resetting
          
          uint datasize = cast(uint)(sample_total * bytesz * channels);
          
          // RIFF signature, media chunk size, and media type
          U4 sz = U4(cast(uint)(
               ChunkHeader.sizeof + FormatChunk.sizeof +
               ChunkHeader.sizeof + datasize));
          file.rawWrite("RIFF");
          file.rawWrite(sz.buffer);
          file.rawWrite("WAVE");
          
          // Format chunk
          sz = U4(cast(uint)FormatChunk.sizeof);
          file.rawWrite("fmt ");
          file.rawWrite(sz.buffer);
          file.rawWrite(fmtbuf);
          
          // Prep data chunk
          sz = U4(cast(uint)datasize);
          file.rawWrite("data");
          file.rawWrite(sz.buffer);
     }
     /// Old alias
     alias setinfo = writeHeader;
     
     void write(T = short)(T[] samples)
     {
          if (samples.length == 0)
               return;
          
          // write samples
          /*
          if (fmt.samplebits == 24)
               foreach (samp; samples)
               {
                    U4 u4 = U4(samp);
                    file.rawWrite(u4.buffer[0..3]);
               }
          else
          */
               file.rawWrite(samples);
     }
     
private:
     File file;
     
     uint totalsize;
     union
     {
          FormatChunk fmt;
          ubyte[FormatChunk.sizeof] fmtbuf;
     }
     union U4
     {
          uint value;
          ubyte[uint.sizeof] buffer;
     }
}

private:

template CHAR32LE(char[4] t)
{
     enum uint CHAR32LE =
          (t[3] << 24) | (t[2] << 16) |
          (t[1] << 8)  |  t[0];
}
static assert(CHAR32LE!"fmt " == 0x20746D66);

enum SIGRIFF        = CHAR32LE!"RIFF"; /// RIFF file signature
enum RIFFWAVE       = CHAR32LE!"WAVE"; /// WAVE RIFF media type
//enum FMT_CHUNK = 0x20746D66; // "fmt "
enum CHUNK_FORMAT   = CHAR32LE!"fmt "; /// Format chunk ID
enum CHUNK_SILENCE  = CHAR32LE!"slnt"; /// Silence chunk ID
enum CHUNK_DATA     = CHAR32LE!"data"; /// Data chunk ID
enum CHUNK_LABEL    = CHAR32LE!"labl"; /// Label chunk ID
enum CHUNK_NOTE     = CHAR32LE!"note"; /// Label chunk ID

// 0x3bbb8 = 
enum SPEAKER_FRONT_LEFT             = 0x1;
enum SPEAKER_FRONT_RIGHT            = 0x2;
enum SPEAKER_FRONT_CENTER           = 0x4;
enum SPEAKER_LOW_FREQUENCY          = 0x8;
enum SPEAKER_BACK_LEFT              = 0x10;
enum SPEAKER_BACK_RIGHT             = 0x20;
enum SPEAKER_FRONT_LEFT_OF_CENTER   = 0x40;
enum SPEAKER_FRONT_RIGHT_OF_CENTER  = 0x80;
enum SPEAKER_BACK_CENTER            = 0x100;
enum SPEAKER_SIDE_LEFT              = 0x200;
enum SPEAKER_SIDE_RIGHT             = 0x400;
enum SPEAKER_TOP_CENTER             = 0x800;
enum SPEAKER_TOP_FRONT_LEFT         = 0x1000;
enum SPEAKER_TOP_FRONT_CENTER       = 0x2000;
enum SPEAKER_TOP_FRONT_RIGHT        = 0x4000;
enum SPEAKER_TOP_BACK_LEFT          = 0x8000;
enum SPEAKER_TOP_BACK_CENTER        = 0x10000;
enum SPEAKER_TOP_BACK_RIGHT         = 0x20000;
enum SPEAKER_RESERVED               = 0x80000000;

// HACK: To allow rawRead to "read" structures
union _CHBuf
{
     ChunkHeader header;
     ubyte[ChunkHeader.sizeof] buffer;
}

struct ChunkHeader
{
     align(1):
     union
     {
          char[4] id;
          uint id32;
     }
     uint cksize; // size excluding this header
}