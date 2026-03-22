#[cfg(feature = "uac2")]
mod uac2_performance {
    use rust_lib_flick_player::uac2::*;
    use std::time::Instant;

    #[test]
    #[ignore]
    fn test_ring_buffer_throughput() {
        let mut buffer = RingBuffer::new(1024 * 1024).unwrap();
        let chunk_size = 4096;
        let iterations = 1000;
        
        let data = vec![0u8; chunk_size];
        let mut output = vec![0u8; chunk_size];
        
        let start = Instant::now();
        
        for _ in 0..iterations {
            buffer.write(&data).unwrap();
            buffer.read(&mut output).unwrap();
        }
        
        let elapsed = start.elapsed();
        let throughput = (chunk_size * iterations) as f64 / elapsed.as_secs_f64();
        
        println!("Ring buffer throughput: {:.2} MB/s", throughput / 1_000_000.0);
        assert!(throughput > 10_000_000.0, "Throughput too low");
    }

    #[test]
    #[ignore]
    fn test_audio_pipeline_latency() {
        let format = AudioFormat::new(
            FormatType::Pcm,
            BitDepth::Bits16,
            vec![SampleRate::new(48000).unwrap()],
            ChannelConfig::Stereo,
        ).unwrap();
        
        let pipeline = AudioPipeline::new(
            format.clone(),
            format,
            8192,
        ).unwrap();
        
        let chunk_size = 192;
        let data = vec![0u8; chunk_size];
        let mut output = vec![0u8; chunk_size];
        
        let iterations = 1000;
        let mut total_latency = std::time::Duration::ZERO;
        
        for _ in 0..iterations {
            let start = Instant::now();
            pipeline.process(&data).unwrap();
            pipeline.read(&mut output).unwrap();
            total_latency += start.elapsed();
        }
        
        let avg_latency = total_latency / iterations;
        println!("Average pipeline latency: {:?}", avg_latency);
        assert!(avg_latency < std::time::Duration::from_micros(100));
    }

    #[test]
    #[ignore]
    fn test_format_conversion_performance() {
        let source = AudioFormat::new(
            FormatType::Pcm,
            BitDepth::Bits16,
            vec![SampleRate::new(44100).unwrap()],
            ChannelConfig::Stereo,
        ).unwrap();
        
        let target = AudioFormat::new(
            FormatType::Pcm,
            BitDepth::Bits24,
            vec![SampleRate::new(44100).unwrap()],
            ChannelConfig::Stereo,
        ).unwrap();
        
        let pipeline = AudioPipeline::new(source, target, 16384).unwrap();
        
        let chunk_size = 4096;
        let data = vec![0u8; chunk_size];
        let iterations = 1000;
        
        let start = Instant::now();
        
        for _ in 0..iterations {
            pipeline.process(&data).unwrap();
        }
        
        let elapsed = start.elapsed();
        let throughput = (chunk_size * iterations) as f64 / elapsed.as_secs_f64();
        
        println!("Conversion throughput: {:.2} MB/s", throughput / 1_000_000.0);
        assert!(throughput > 5_000_000.0);
    }

    #[test]
    #[ignore]
    fn test_passthrough_performance() {
        let format = AudioFormat::new(
            FormatType::Pcm,
            BitDepth::Bits24,
            vec![SampleRate::new(96000).unwrap()],
            ChannelConfig::Stereo,
        ).unwrap();
        
        let pipeline = AudioPipeline::new(
            format.clone(),
            format,
            16384,
        ).unwrap();
        
        assert!(pipeline.is_passthrough());
        
        let chunk_size = 4096;
        let data = vec![0u8; chunk_size];
        let iterations = 10000;
        
        let start = Instant::now();
        
        for _ in 0..iterations {
            pipeline.process(&data).unwrap();
        }
        
        let elapsed = start.elapsed();
        let throughput = (chunk_size * iterations) as f64 / elapsed.as_secs_f64();
        
        println!("Passthrough throughput: {:.2} MB/s", throughput / 1_000_000.0);
        assert!(throughput > 50_000_000.0);
    }

    #[test]
    #[ignore]
    fn test_device_enumeration_performance() {
        let iterations = 10;
        let mut total_time = std::time::Duration::ZERO;
        
        for _ in 0..iterations {
            let start = Instant::now();
            let _ = enumerate_uac2_devices();
            total_time += start.elapsed();
        }
        
        let avg_time = total_time / iterations;
        println!("Average enumeration time: {:?}", avg_time);
        assert!(avg_time < std::time::Duration::from_millis(100));
    }

    #[test]
    #[ignore]
    fn test_buffer_allocation_performance() {
        let iterations = 1000;
        let buffer_size = 16384;
        
        let start = Instant::now();
        
        for _ in 0..iterations {
            let _ = RingBuffer::new(buffer_size).unwrap();
        }
        
        let elapsed = start.elapsed();
        let avg_time = elapsed / iterations;
        
        println!("Average buffer allocation time: {:?}", avg_time);
        assert!(avg_time < std::time::Duration::from_micros(50));
    }

    #[test]
    #[ignore]
    fn test_format_matching_performance() {
        let formats: Vec<AudioFormat> = vec![
            AudioFormat::new(
                FormatType::Pcm,
                BitDepth::Bits16,
                vec![SampleRate::new(44100).unwrap()],
                ChannelConfig::Stereo,
            ).unwrap(),
            AudioFormat::new(
                FormatType::Pcm,
                BitDepth::Bits24,
                vec![SampleRate::new(48000).unwrap()],
                ChannelConfig::Stereo,
            ).unwrap(),
            AudioFormat::new(
                FormatType::Pcm,
                BitDepth::Bits32,
                vec![SampleRate::new(96000).unwrap()],
                ChannelConfig::Stereo,
            ).unwrap(),
        ];
        
        let iterations = 10000;
        let start = Instant::now();
        
        for _ in 0..iterations {
            let _ = FormatMatcher::find_optimal_format(
                &formats,
                Some(SampleRate::new(48000).unwrap()),
                Some(BitDepth::Bits24),
            );
        }
        
        let elapsed = start.elapsed();
        let avg_time = elapsed / iterations;
        
        println!("Average format matching time: {:?}", avg_time);
        assert!(avg_time < std::time::Duration::from_micros(10));
    }

    #[test]
    #[ignore]
    fn test_low_latency_streaming_simulation() {
        let format = AudioFormat::new(
            FormatType::Pcm,
            BitDepth::Bits24,
            vec![SampleRate::new(96000).unwrap()],
            ChannelConfig::Stereo,
        ).unwrap();
        
        let pipeline = AudioPipeline::new(
            format.clone(),
            format,
            4096,
        ).unwrap();
        
        let frame_size = 6;
        let frames_per_packet = 32;
        let packet_size = frame_size * frames_per_packet;
        
        let data = vec![0u8; packet_size];
        let mut output = vec![0u8; packet_size];
        
        let packets = 1000;
        let mut max_latency = std::time::Duration::ZERO;
        let mut total_latency = std::time::Duration::ZERO;
        
        for _ in 0..packets {
            let start = Instant::now();
            pipeline.process(&data).unwrap();
            pipeline.read(&mut output).unwrap();
            let latency = start.elapsed();
            
            total_latency += latency;
            if latency > max_latency {
                max_latency = latency;
            }
        }
        
        let avg_latency = total_latency / packets;
        
        println!("Low-latency streaming test:");
        println!("  Average latency: {:?}", avg_latency);
        println!("  Max latency: {:?}", max_latency);
        
        assert!(avg_latency < std::time::Duration::from_micros(50));
        assert!(max_latency < std::time::Duration::from_micros(200));
    }
}
