use crate::uac2::ring_buffer::{AudioBuffer, RingBuffer};

#[test]
fn test_ring_buffer_creation() {
    let buffer = RingBuffer::new(8192);
    assert!(buffer.is_ok());
    
    let buffer = RingBuffer::new(0);
    assert!(buffer.is_err());
}

#[test]
fn test_ring_buffer_write_read() {
    let mut buffer = RingBuffer::new(8192).unwrap();
    let data = vec![1u8, 2, 3, 4, 5];
    
    let written = buffer.write(&data).unwrap();
    assert_eq!(written, 5);
    assert_eq!(buffer.available(), 5);
    
    let mut output = vec![0u8; 5];
    let read = buffer.read(&mut output).unwrap();
    assert_eq!(read, 5);
    assert_eq!(output, data);
    assert_eq!(buffer.available(), 0);
}

#[test]
fn test_ring_buffer_overflow() {
    let mut buffer = RingBuffer::new(4096).unwrap();
    let data = vec![1u8; 5000];
    
    let written = buffer.write(&data).unwrap();
    assert_eq!(written, 4096);
    assert_eq!(buffer.available(), 4096);
}

#[test]
fn test_ring_buffer_underflow() {
    let mut buffer = RingBuffer::new(8192).unwrap();
    let data = vec![1u8; 5];
    
    buffer.write(&data).unwrap();
    
    let mut output = vec![0u8; 10];
    let read = buffer.read(&mut output).unwrap();
    assert_eq!(read, 5);
}

#[test]
fn test_ring_buffer_wrap_around() {
    let mut buffer = RingBuffer::new(4096).unwrap();
    
    let data1 = vec![1u8; 3000];
    buffer.write(&data1).unwrap();
    
    let mut output = vec![0u8; 2000];
    buffer.read(&mut output).unwrap();
    
    let data2 = vec![2u8; 3000];
    let written = buffer.write(&data2).unwrap();
    assert_eq!(written, 3000);
    assert_eq!(buffer.available(), 4000);
}

#[test]
fn test_ring_buffer_multiple_operations() {
    let mut buffer = RingBuffer::new(8192).unwrap();
    
    for i in 0..10 {
        let data = vec![i as u8; 100];
        buffer.write(&data).unwrap();
        
        let mut output = vec![0u8; 100];
        buffer.read(&mut output).unwrap();
        
        assert_eq!(output, data);
    }
}
