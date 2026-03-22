use crate::uac2::audio_format::{BitDepth, ChannelConfig, SampleRate};
use crate::uac2::stream_config::{StreamConfig, StreamConfigBuilder};

#[test]
fn test_stream_config_builder() {
    let config = StreamConfigBuilder::new()
        .sample_rate(SampleRate::new(48000).unwrap())
        .bit_depth(BitDepth::Bits24)
        .channels(ChannelConfig::Stereo)
        .endpoint_address(0x01)
        .build();
    
    assert!(config.is_ok());
    let config = config.unwrap();
    assert_eq!(config.sample_rate.hz(), 48000);
    assert_eq!(config.bit_depth.bits(), 24);
    assert_eq!(config.channels.count(), 2);
    assert_eq!(config.endpoint_address, 0x01);
}

#[test]
fn test_stream_config_builder_missing_fields() {
    let config = StreamConfigBuilder::new()
        .sample_rate(SampleRate::new(48000).unwrap())
        .build();
    
    assert!(config.is_err());
}

#[test]
fn test_stream_config_bytes_per_frame() {
    let config = StreamConfig {
        sample_rate: SampleRate::new(48000).unwrap(),
        bit_depth: BitDepth::Bits16,
        channels: ChannelConfig::Stereo,
        endpoint_address: 0x01,
        packet_size: 192,
        interval: 1,
    };
    
    assert_eq!(config.bytes_per_frame(), 4);
}

#[test]
fn test_stream_config_bytes_per_frame_24bit() {
    let config = StreamConfig {
        sample_rate: SampleRate::new(48000).unwrap(),
        bit_depth: BitDepth::Bits24,
        channels: ChannelConfig::Stereo,
        endpoint_address: 0x01,
        packet_size: 288,
        interval: 1,
    };
    
    assert_eq!(config.bytes_per_frame(), 6);
}

#[test]
fn test_stream_config_different_sample_rates() {
    let rates = vec![44100, 48000, 96000, 192000];
    
    for rate in rates {
        let config = StreamConfigBuilder::new()
            .sample_rate(SampleRate::new(rate).unwrap())
            .bit_depth(BitDepth::Bits16)
            .channels(ChannelConfig::Stereo)
            .endpoint_address(0x01)
            .build();
        
        assert!(config.is_ok());
        assert_eq!(config.unwrap().sample_rate.hz(), rate);
    }
}

#[test]
fn test_stream_config_different_bit_depths() {
    let depths = vec![BitDepth::Bits16, BitDepth::Bits24, BitDepth::Bits32];
    
    for depth in depths {
        let config = StreamConfigBuilder::new()
            .sample_rate(SampleRate::new(48000).unwrap())
            .bit_depth(depth)
            .channels(ChannelConfig::Stereo)
            .endpoint_address(0x01)
            .build();
        
        assert!(config.is_ok());
        assert_eq!(config.unwrap().bit_depth, depth);
    }
}

#[test]
fn test_stream_config_different_channels() {
    let channels = vec![
        ChannelConfig::Mono,
        ChannelConfig::Stereo,
        ChannelConfig::MultiChannel(6),
        ChannelConfig::MultiChannel(8),
    ];
    
    for channel in channels {
        let config = StreamConfigBuilder::new()
            .sample_rate(SampleRate::new(48000).unwrap())
            .bit_depth(BitDepth::Bits16)
            .channels(channel)
            .endpoint_address(0x01)
            .build();
        
        assert!(config.is_ok());
        assert_eq!(config.unwrap().channels, channel);
    }
}
