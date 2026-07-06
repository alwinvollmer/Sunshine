/**
 * @file src/platform/macos/microphone.mm
 * @brief Definitions for microphone capture on macOS.
 */
// local includes
#include "src/config.h"
#include "src/logging.h"
#include "src/platform/common.h"
#include "src/platform/macos/av_audio.h"

namespace platf {
  using namespace std::literals;

  /**
   * @brief macOS microphone capture device and audio format state.
   */
  struct av_mic_t: public mic_t {
    AVAudio *av_audio_capture {};  ///< AV audio capture.

    ~av_mic_t() override {
      [av_audio_capture release];
    }

    /**
     * @brief Deliver a captured audio sample to Sunshine's audio pipeline.
     *
     * @param sample_in Sample in.
     * @return Capture status reported to the streaming pipeline.
     */
    capture_e sample(std::vector<float> &sample_in) override {
      const uint32_t neededBytes = static_cast<uint32_t>(sample_in.size() * sizeof(float));
      uint8_t *dst = reinterpret_cast<uint8_t *>(sample_in.data());

      uint32_t remaining = neededBytes;

      while (remaining > 0) {
        uint32_t avail = 0;
        void *tail = TPCircularBufferTail(&av_audio_capture->audioSampleBuffer, &avail);

        if (avail == 0) {
          // Using 5 second timeout to prevent indefinite hanging
          dispatch_time_t timeout = dispatch_time(DISPATCH_TIME_NOW, 5LL * NSEC_PER_SEC);
  struct av_mic_output_t: public mic_output_t {
    AVAudio *av_audio_output;
    std::string device_name;
    bool started = false;

    av_mic_output_t(int channels, std::uint32_t sample_rate, const std::string &dev_name) 
      : device_name(dev_name) {
      
      av_audio_output = [[AVAudio alloc] init];
      
      AVCaptureDevice *output_device = nullptr;
      if (!device_name.empty() && device_name != "default") {
        output_device = [AVAudio findMicrophone:[NSString stringWithUTF8String:device_name.c_str()]];
      }
      
      if (!output_device) {
        output_device = [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeAudio];
      }
      
      if ([av_audio_output setupMicrophone:output_device sampleRate:sample_rate frameSize:960 channels:channels]) {
        BOOST_LOG(error) << "Failed to setup microphone output device."sv;
        [av_audio_output release];
        av_audio_output = nullptr;
      }
    }

    int output_samples(const std::vector<float> &frame_buffer) override {
      if (!av_audio_output || !started) {
        return -1;
      }

      // For macOS, we would need to implement audio output through Core Audio
      // This is a simplified placeholder - real implementation would need
      // Audio Queue Services or Audio Unit for output
      BOOST_LOG(debug) << "Outputting " << frame_buffer.size() << " audio samples"sv;
      return 0;
    }

    int start() override {
      started = av_audio_output != nullptr;
      return started ? 0 : -1;
    }

    int stop() override {
      started = false;
      return 0;
    }

    ~av_mic_output_t() override {
      stop();
      if (av_audio_output) {
        [av_audio_output release];
      }
    }
  };

          if (dispatch_semaphore_wait(av_audio_capture->audioSemaphore, timeout) != 0) {
            BOOST_LOG(warning) << "Audio sample timeout - no audio data received within 5 seconds"sv;

            // Fill with silence and return to prevent hanging
            std::fill(sample_in.begin(), sample_in.end(), 0.0f);
            return capture_e::timeout;
          }
          continue;
        }

        const uint32_t toCopy = (avail < remaining) ? avail : remaining;
        std::memcpy(dst, tail, toCopy);

        TPCircularBufferConsume(&av_audio_capture->audioSampleBuffer, toCopy);

        dst += toCopy;
        remaining -= toCopy;
      }

      return capture_e::ok;
    }
  };

  /**
   * @brief macOS audio control state used to create microphone streams.
   */
  struct macos_audio_control_t: public audio_control_t {
    AVCaptureDevice *audio_capture_device {};  ///< Audio capture device.

  public:
    /**
     * @brief Update the sink value on the backend.
     *
     * @param sink Audio sink name to route or capture.
     * @return Status from updating sink.
     */
    int set_sink(const std::string &sink) override {
      BOOST_LOG(warning) << "audio_control_t::set_sink() unimplemented: "sv << sink;
      return 0;
    }

    /**
     * @brief Create a microphone capture stream for the requested layout.
     *
     * @param mapping Opus channel mapping table for the requested layout.
     * @param channels Number of audio channels in the stream.
     * @param sample_rate Audio sample rate in hertz.
     * @param frame_size Number of samples captured per audio frame.
     * @param continuous_audio Continuous audio.
     * @param host_audio_enabled Whether host playback should remain enabled during capture.
     * @return Microphone capture object for the requested audio layout.
     */
    std::unique_ptr<mic_t> microphone(const std::uint8_t *mapping, int channels, std::uint32_t sample_rate, std::uint32_t frame_size, bool continuous_audio, bool host_audio_enabled) override {
      auto mic = std::make_unique<av_mic_t>();
      mic->av_audio_capture = [[AVAudio alloc] init];

      // Set the host audio enabled flag from the stream configuration
      mic->av_audio_capture.hostAudioEnabled = host_audio_enabled ? YES : NO;
      BOOST_LOG(debug) << "Set hostAudioEnabled to: "sv << (host_audio_enabled ? "YES" : "NO");

      if (config::audio.sink.empty()) {
        // Use macOS system-wide audio tap
        BOOST_LOG(info) << "Using macOS system audio tap for capture."sv;
        BOOST_LOG(info) << "Sample rate: "sv << sample_rate << ", Frame size: "sv << frame_size << ", Channels: "sv << channels;

        if ([mic->av_audio_capture setupSystemTap:sample_rate frameSize:frame_size channels:channels]) {
          BOOST_LOG(error) << "Failed to setup system audio tap."sv;
          return nullptr;
        }
      } else {
        // Use specified macOS audio sink
        const char *audio_sink = config::audio.sink.c_str();
        BOOST_LOG(info) << "Using configured audio sink "sv << audio_sink << " for capture."sv;

        if ((audio_capture_device = [AVAudio findMicrophone:[NSString stringWithUTF8String:audio_sink]]) == nullptr) {
          BOOST_LOG(error) << "opening microphone '"sv << audio_sink << "' failed. Please set a valid input source in the Sunshine config."sv;
          BOOST_LOG(error) << "Available inputs:"sv;

          for (NSString *name in [AVAudio microphoneNames]) {
            BOOST_LOG(error) << "\t"sv << [name UTF8String];
          }

          return nullptr;
        }

        if ([mic->av_audio_capture setupMicrophone:audio_capture_device sampleRate:sample_rate frameSize:frame_size channels:channels]) {
          BOOST_LOG(error) << "Failed to setup microphone."sv;
          return nullptr;
        }
      }

      return mic;
    }

    std::unique_ptr<mic_output_t> mic_output(int channels, std::uint32_t sample_rate, const std::string &device_name) override {
      return std::make_unique<av_mic_output_t>(channels, sample_rate, device_name);
    }

    bool is_sink_available(const std::string &sink) override {
      BOOST_LOG(warning) << "audio_control_t::is_sink_available() unimplemented: "sv << sink;
      return true;
    }

    /**
     * @brief Query host and virtual sink names available to Sunshine.
     *
     * @return Host and virtual sink names when the backend can report them.
     */
    std::optional<sink_t> sink_info() override {
      sink_t sink;

      return sink;
    }
  };

  std::unique_ptr<audio_control_t> audio_control() {
    return std::make_unique<macos_audio_control_t>();
  }
}  // namespace platf
