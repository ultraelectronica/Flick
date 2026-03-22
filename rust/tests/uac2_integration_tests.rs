#[cfg(feature = "uac2")]
mod uac2_integration {
    use rust_lib_flick_player::uac2::*;

    #[test]
    #[ignore]
    fn test_device_enumeration() {
        let devices = enumerate_uac2_devices();
        
        match devices {
            Ok(device_list) => {
                println!("Found {} UAC2 devices", device_list.len());
                for device in device_list {
                    println!("Device: {} by {}", 
                        device.metadata.product_name,
                        device.metadata.manufacturer
                    );
                    println!("  VID: {:04x}, PID: {:04x}",
                        device.identification.vendor_id,
                        device.identification.product_id
                    );
                }
            }
            Err(e) => {
                println!("Device enumeration failed: {}", e);
            }
        }
    }

    #[test]
    fn test_audio_format_validation() {
        let format = AudioFormat::new(
            FormatType::Pcm,
            BitDepth::Bits16,
            vec![SampleRate::new(44100).unwrap()],
            ChannelConfig::Stereo,
        );
        
        assert!(format.is_ok());
    }

    #[test]
    fn test_stream_config_creation() {
        let config = StreamConfigBuilder::new()
            .sample_rate(SampleRate::new(48000).unwrap())
            .bit_depth(BitDepth::Bits24)
            .channels(ChannelConfig::Stereo)
            .endpoint_address(0x01)
            .packet_size(192)
            .interval(1)
            .build();
        
        assert!(config.is_ok());
    }

    #[test]
    fn test_audio_pipeline_bit_perfect() {
        let format = AudioFormat::new(
            FormatType::Pcm,
            BitDepth::Bits24,
            vec![SampleRate::new(96000).unwrap()],
            ChannelConfig::Stereo,
        ).unwrap();
        
        let pipeline = AudioPipeline::new(
            format.clone(),
            format,
            8192,
        );
        
        assert!(pipeline.is_ok());
        assert!(pipeline.unwrap().is_passthrough());
    }

    #[test]
    fn test_device_matching_logic() {
        let requirements = AudioRequirements::new()
            .with_sample_rate(SampleRate::new(48000).unwrap())
            .with_bit_depth(BitDepth::Bits24);
        
        assert_eq!(requirements.min_sample_rate.unwrap().hz(), 48000);
        assert_eq!(requirements.min_bit_depth.unwrap().bits(), 24);
    }

    #[test]
    fn test_ring_buffer_operations() {
        let mut buffer = RingBuffer::new(4096).unwrap();
        
        let test_data = vec![1u8, 2, 3, 4, 5, 6, 7, 8];
        let written = buffer.write(&test_data).unwrap();
        assert_eq!(written, test_data.len());
        
        let mut output = vec![0u8; test_data.len()];
        let read = buffer.read(&mut output).unwrap();
        assert_eq!(read, test_data.len());
        assert_eq!(output, test_data);
    }

    #[test]
    fn test_format_negotiation() {
        let source = AudioFormat::new(
            FormatType::Pcm,
            BitDepth::Bits16,
            vec![SampleRate::new(44100).unwrap()],
            ChannelConfig::Stereo,
        ).unwrap();
        
        let target = AudioFormat::new(
            FormatType::Pcm,
            BitDepth::Bits24,
            vec![SampleRate::new(48000).unwrap()],
            ChannelConfig::Stereo,
        ).unwrap();
        
        let negotiator = FormatNegotiator::new(source, target);
        assert!(negotiator.is_ok());
    }

    #[test]
    fn test_logging_configuration() {
        let config = LogConfig::production();
        assert_eq!(config.level, LogLevel::Info);
        assert!(config.enable_device_discovery);
        assert!(!config.enable_descriptor_parsing);
        
        let debug_config = LogConfig::debug();
        assert_eq!(debug_config.level, LogLevel::Debug);
        assert!(debug_config.enable_descriptor_parsing);
    }

    #[test]
    fn test_error_recovery_strategy() {
        let strategy = RecoveryStrategy::Reconnect { max_attempts: 3 };
        
        match strategy {
            RecoveryStrategy::Reconnect { max_attempts } => {
                assert_eq!(max_attempts, 3);
            }
            _ => panic!("Wrong strategy type"),
        }
    }

    #[test]
    fn test_connection_state_transitions() {
        let manager = ConnectionManager::<rusb::Context>::new(true);
        assert_eq!(manager.state(), ConnectionState::Disconnected);
        assert!(!manager.is_connected());
    }

    #[test]
    #[ignore]
    fn test_bit_perfect_verification() {
        let source_format = AudioFormat::new(
            FormatType::Pcm,
            BitDepth::Bits24,
            vec![SampleRate::new(96000).unwrap()],
            ChannelConfig::Stereo,
        ).unwrap();
        
        let pipeline = AudioPipeline::new(
            source_format.clone(),
            source_format,
            16384,
        ).unwrap();
        
        let test_data: Vec<u8> = (0..1000).map(|i| (i % 256) as u8).collect();
        
        pipeline.process(&test_data).unwrap();
        
        let mut output = vec![0u8; test_data.len()];
        let read = pipeline.read(&mut output).unwrap();
        
        assert_eq!(read, test_data.len());
        assert_eq!(output, test_data, "Bit-perfect verification failed");
    }

    #[test]
    fn test_transfer_stats_tracking() {
        let mut stats = TransferStats::new();
        
        for _ in 0..100 {
            stats.record_submit();
            stats.record_completion();
        }
        
        assert_eq!(stats.total_submitted, 100);
        assert_eq!(stats.total_completed, 100);
        assert_eq!(stats.success_rate(), 1.0);
    }
}
