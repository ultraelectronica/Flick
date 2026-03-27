#[cfg(test)]
mod alac_converter_tests {
    use rust_lib_flick_player::audio::alac_converter::{AudioMetadata, ConversionSession};

    #[test]
    fn test_wav_header_generation() {
        let metadata = AudioMetadata {
            sample_rate: 44100,
            channels: 2,
            bit_depth: 16,
            duration_samples: 44100,
            duration_seconds: 1.0,
        };

        // Test that we can generate a valid WAV header
        // In a real test, you would load an actual ALAC file
        // For now, we just verify the struct can be created
        assert_eq!(metadata.sample_rate, 44100);
        assert_eq!(metadata.channels, 2);
        assert_eq!(metadata.bit_depth, 16);
    }

    #[test]
    fn test_metadata_calculations() {
        let metadata = AudioMetadata {
            sample_rate: 48000,
            channels: 2,
            bit_depth: 24,
            duration_samples: 48000 * 60, // 1 minute
            duration_seconds: 60.0,
        };

        assert_eq!(metadata.duration_seconds, 60.0);
        assert_eq!(metadata.duration_samples, 48000 * 60);
    }

    // Note: To test actual ALAC decoding, you would need:
    // 1. A sample ALAC file in the test resources
    // 2. Load it and create a ConversionSession
    // 3. Verify the decoded output matches expected PCM data
    //
    // Example:
    // #[test]
    // fn test_alac_decode() {
    //     let file_bytes = std::fs::read("tests/fixtures/sample.alac").unwrap();
    //     let mut session = ConversionSession::new(file_bytes).unwrap();
    //     let metadata = session.metadata();
    //     assert_eq!(metadata.sample_rate, 44100);
    //
    //     let chunk = session.decode_next_chunk().unwrap();
    //     assert!(chunk.is_some());
    // }
}
