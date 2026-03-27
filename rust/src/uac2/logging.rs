use std::sync::Once;
use tracing::Level;
use tracing_subscriber::{
    filter::{EnvFilter, LevelFilter},
    fmt,
    layer::SubscriberExt,
    util::SubscriberInitExt,
    Layer,
};

static INIT: Once = Once::new();

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum LogLevel {
    Error,
    Warn,
    Info,
    Debug,
    Trace,
}

impl From<LogLevel> for Level {
    fn from(level: LogLevel) -> Self {
        match level {
            LogLevel::Error => Level::ERROR,
            LogLevel::Warn => Level::WARN,
            LogLevel::Info => Level::INFO,
            LogLevel::Debug => Level::DEBUG,
            LogLevel::Trace => Level::TRACE,
        }
    }
}

impl From<LogLevel> for LevelFilter {
    fn from(level: LogLevel) -> Self {
        match level {
            LogLevel::Error => LevelFilter::ERROR,
            LogLevel::Warn => LevelFilter::WARN,
            LogLevel::Info => LevelFilter::INFO,
            LogLevel::Debug => LevelFilter::DEBUG,
            LogLevel::Trace => LevelFilter::TRACE,
        }
    }
}

pub struct LogConfig {
    pub level: LogLevel,
    pub enable_device_discovery: bool,
    pub enable_descriptor_parsing: bool,
    pub enable_control_requests: bool,
    pub enable_streaming_stats: bool,
    pub enable_transfer_details: bool,
}

impl LogConfig {
    pub fn new(level: LogLevel) -> Self {
        Self {
            level,
            enable_device_discovery: level as u8 >= LogLevel::Info as u8,
            enable_descriptor_parsing: level as u8 >= LogLevel::Debug as u8,
            enable_control_requests: level as u8 >= LogLevel::Debug as u8,
            enable_streaming_stats: level as u8 >= LogLevel::Info as u8,
            enable_transfer_details: level as u8 >= LogLevel::Trace as u8,
        }
    }

    pub fn debug() -> Self {
        Self {
            level: LogLevel::Debug,
            enable_device_discovery: true,
            enable_descriptor_parsing: true,
            enable_control_requests: true,
            enable_streaming_stats: true,
            enable_transfer_details: false,
        }
    }

    pub fn verbose() -> Self {
        Self {
            level: LogLevel::Trace,
            enable_device_discovery: true,
            enable_descriptor_parsing: true,
            enable_control_requests: true,
            enable_streaming_stats: true,
            enable_transfer_details: true,
        }
    }

    pub fn production() -> Self {
        Self {
            level: LogLevel::Info,
            enable_device_discovery: true,
            enable_descriptor_parsing: false,
            enable_control_requests: false,
            enable_streaming_stats: true,
            enable_transfer_details: false,
        }
    }
}

impl Default for LogConfig {
    fn default() -> Self {
        Self::production()
    }
}

pub fn init_logging(config: &LogConfig) {
    INIT.call_once(|| {
        let filter = EnvFilter::try_from_default_env().unwrap_or_else(|_| {
            EnvFilter::new(format!("flick_player::uac2={}", level_to_str(config.level)))
        });

        let fmt_layer = fmt::layer()
            .with_target(true)
            .with_thread_ids(true)
            .with_line_number(true)
            .with_filter(filter);

        tracing_subscriber::registry().with(fmt_layer).init();
    });
}

fn level_to_str(level: LogLevel) -> &'static str {
    match level {
        LogLevel::Error => "error",
        LogLevel::Warn => "warn",
        LogLevel::Info => "info",
        LogLevel::Debug => "debug",
        LogLevel::Trace => "trace",
    }
}

pub struct LogContext {
    config: LogConfig,
}

impl LogContext {
    pub fn new(config: LogConfig) -> Self {
        init_logging(&config);
        Self { config }
    }

    pub fn should_log_device_discovery(&self) -> bool {
        self.config.enable_device_discovery
    }

    pub fn should_log_descriptor_parsing(&self) -> bool {
        self.config.enable_descriptor_parsing
    }

    pub fn should_log_control_requests(&self) -> bool {
        self.config.enable_control_requests
    }

    pub fn should_log_streaming_stats(&self) -> bool {
        self.config.enable_streaming_stats
    }

    pub fn should_log_transfer_details(&self) -> bool {
        self.config.enable_transfer_details
    }
}

impl Default for LogContext {
    fn default() -> Self {
        Self::new(LogConfig::default())
    }
}
