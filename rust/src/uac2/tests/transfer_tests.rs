use crate::uac2::transfer::{TransferContext, TransferStats, TransferStatus, TransferError};
use std::time::Duration;

#[test]
fn test_transfer_context_creation() {
    let context = TransferContext::new(0);
    assert_eq!(context.buffer_index, 0);
    assert_eq!(context.retry_count, 0);
}

#[test]
fn test_transfer_context_elapsed() {
    let context = TransferContext::new(0);
    std::thread::sleep(Duration::from_millis(10));
    assert!(context.elapsed() >= Duration::from_millis(10));
}

#[test]
fn test_transfer_context_should_retry() {
    let mut context = TransferContext::new(0);
    assert!(context.should_retry());
    
    context.increment_retry();
    assert!(context.should_retry());
    
    context.increment_retry();
    assert!(context.should_retry());
    
    context.increment_retry();
    assert!(!context.should_retry());
}

#[test]
fn test_transfer_context_increment_retry() {
    let mut context = TransferContext::new(0);
    assert_eq!(context.retry_count, 0);
    
    context.increment_retry();
    assert_eq!(context.retry_count, 1);
    
    context.increment_retry();
    assert_eq!(context.retry_count, 2);
}

#[test]
fn test_transfer_stats_creation() {
    let stats = TransferStats::new();
    assert_eq!(stats.total_submitted, 0);
    assert_eq!(stats.total_completed, 0);
    assert_eq!(stats.total_failed, 0);
    assert_eq!(stats.total_retried, 0);
    assert_eq!(stats.underruns, 0);
    assert_eq!(stats.overruns, 0);
}

#[test]
fn test_transfer_stats_record_operations() {
    let mut stats = TransferStats::new();
    
    stats.record_submit();
    assert_eq!(stats.total_submitted, 1);
    
    stats.record_completion();
    assert_eq!(stats.total_completed, 1);
    
    stats.record_failure();
    assert_eq!(stats.total_failed, 1);
    
    stats.record_retry();
    assert_eq!(stats.total_retried, 1);
    
    stats.record_underrun();
    assert_eq!(stats.underruns, 1);
    
    stats.record_overrun();
    assert_eq!(stats.overruns, 1);
}

#[test]
fn test_transfer_stats_success_rate() {
    let mut stats = TransferStats::new();
    assert_eq!(stats.success_rate(), 0.0);
    
    stats.record_submit();
    stats.record_completion();
    assert_eq!(stats.success_rate(), 1.0);
    
    stats.record_submit();
    stats.record_failure();
    assert_eq!(stats.success_rate(), 0.5);
    
    stats.record_submit();
    stats.record_submit();
    stats.record_completion();
    stats.record_completion();
    assert_eq!(stats.success_rate(), 0.75);
}

#[test]
fn test_transfer_status_variants() {
    assert_eq!(TransferStatus::Pending, TransferStatus::Pending);
    assert_ne!(TransferStatus::Pending, TransferStatus::Completed);
    assert_ne!(TransferStatus::Completed, TransferStatus::Failed);
    assert_ne!(TransferStatus::Failed, TransferStatus::Cancelled);
}

#[test]
fn test_transfer_error_variants() {
    assert_eq!(TransferError::Timeout, TransferError::Timeout);
    assert_ne!(TransferError::Timeout, TransferError::Overflow);
    assert_ne!(TransferError::Overflow, TransferError::Underflow);
    assert_ne!(TransferError::Stall, TransferError::NoDevice);
}

#[test]
fn test_transfer_error_from_rusb_error() {
    let timeout_err = rusb::Error::Timeout;
    let transfer_err = TransferError::from(timeout_err);
    assert_eq!(transfer_err, TransferError::Timeout);
    
    let overflow_err = rusb::Error::Overflow;
    let transfer_err = TransferError::from(overflow_err);
    assert_eq!(transfer_err, TransferError::Overflow);
    
    let pipe_err = rusb::Error::Pipe;
    let transfer_err = TransferError::from(pipe_err);
    assert_eq!(transfer_err, TransferError::Stall);
    
    let no_device_err = rusb::Error::NoDevice;
    let transfer_err = TransferError::from(no_device_err);
    assert_eq!(transfer_err, TransferError::NoDevice);
}

#[test]
fn test_transfer_stats_multiple_operations() {
    let mut stats = TransferStats::new();
    
    for _ in 0..100 {
        stats.record_submit();
    }
    
    for _ in 0..90 {
        stats.record_completion();
    }
    
    for _ in 0..10 {
        stats.record_failure();
    }
    
    assert_eq!(stats.total_submitted, 100);
    assert_eq!(stats.total_completed, 90);
    assert_eq!(stats.total_failed, 10);
    assert_eq!(stats.success_rate(), 0.9);
}

#[test]
fn test_transfer_stats_default() {
    let stats = TransferStats::default();
    assert_eq!(stats.total_submitted, 0);
    assert_eq!(stats.total_completed, 0);
}
