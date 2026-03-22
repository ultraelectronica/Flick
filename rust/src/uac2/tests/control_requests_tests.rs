use crate::uac2::control_requests::{
    ControlRequest, ControlRequestBuilder, ControlRequestType, ControlSelector, ControlRecipient,
};

#[test]
fn test_control_request_type_codes() {
    assert_eq!(ControlRequestType::GetCur.request_code(), 0x81);
    assert_eq!(ControlRequestType::GetMin.request_code(), 0x82);
    assert_eq!(ControlRequestType::GetMax.request_code(), 0x83);
    assert_eq!(ControlRequestType::GetRes.request_code(), 0x84);
    assert_eq!(ControlRequestType::SetCur.request_code(), 0x01);
}

#[test]
fn test_control_request_type_direction() {
    assert_eq!(ControlRequestType::GetCur.direction(), 0x80);
    assert_eq!(ControlRequestType::GetMin.direction(), 0x80);
    assert_eq!(ControlRequestType::SetCur.direction(), 0x00);
}

#[test]
fn test_control_selector_codes() {
    assert_eq!(ControlSelector::Volume.code(), 0x0100);
    assert_eq!(ControlSelector::Mute.code(), 0x0101);
    assert_eq!(ControlSelector::SamplingFreq.code(), 0x0106);
}

#[test]
fn test_control_recipient_codes() {
    assert_eq!(ControlRecipient::Interface.code(), 0x01);
    assert_eq!(ControlRecipient::Endpoint.code(), 0x02);
}

#[test]
fn test_control_request_builder_complete() {
    let request = ControlRequest::builder()
        .request_type(ControlRequestType::GetCur)
        .selector(ControlSelector::Volume)
        .recipient(ControlRecipient::Interface)
        .interface(0)
        .entity_id(1)
        .channel(0)
        .build();
    
    assert!(request.is_ok());
    let request = request.unwrap();
    assert_eq!(request.request_type(), ControlRequestType::GetCur);
    assert_eq!(request.selector(), ControlSelector::Volume);
}

#[test]
fn test_control_request_builder_missing_request_type() {
    let request = ControlRequest::builder()
        .selector(ControlSelector::Volume)
        .interface(0)
        .entity_id(1)
        .build();
    
    assert!(request.is_err());
}

#[test]
fn test_control_request_builder_missing_selector() {
    let request = ControlRequest::builder()
        .request_type(ControlRequestType::GetCur)
        .interface(0)
        .entity_id(1)
        .build();
    
    assert!(request.is_err());
}

#[test]
fn test_control_request_builder_missing_interface() {
    let request = ControlRequest::builder()
        .request_type(ControlRequestType::GetCur)
        .selector(ControlSelector::Volume)
        .entity_id(1)
        .build();
    
    assert!(request.is_err());
}

#[test]
fn test_control_request_builder_with_value() {
    let request = ControlRequest::builder()
        .request_type(ControlRequestType::SetCur)
        .selector(ControlSelector::Volume)
        .interface(0)
        .entity_id(1)
        .value(0x1000)
        .build();
    
    assert!(request.is_ok());
}

#[test]
fn test_control_request_builder_with_data() {
    let data = vec![0x01, 0x02, 0x03, 0x04];
    let request = ControlRequest::builder()
        .request_type(ControlRequestType::SetCur)
        .selector(ControlSelector::Volume)
        .interface(0)
        .entity_id(1)
        .data(data.clone())
        .build();
    
    assert!(request.is_ok());
}

#[test]
fn test_control_request_builder_default_channel() {
    let request = ControlRequest::builder()
        .request_type(ControlRequestType::GetCur)
        .selector(ControlSelector::Volume)
        .interface(0)
        .entity_id(1)
        .build();
    
    assert!(request.is_ok());
}

#[test]
fn test_control_request_builder_custom_channel() {
    let request = ControlRequest::builder()
        .request_type(ControlRequestType::GetCur)
        .selector(ControlSelector::Volume)
        .interface(0)
        .entity_id(1)
        .channel(2)
        .build();
    
    assert!(request.is_ok());
}

#[test]
fn test_control_request_builder_endpoint_recipient() {
    let request = ControlRequest::builder()
        .request_type(ControlRequestType::GetCur)
        .selector(ControlSelector::SamplingFreq)
        .recipient(ControlRecipient::Endpoint)
        .interface(0)
        .entity_id(0x81)
        .build();
    
    assert!(request.is_ok());
}
