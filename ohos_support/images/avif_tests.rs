#[cfg(test)]
mod ohos_codec_tests {
    use super::*;

    #[test]
    fn static_avif_rgba_and_release() {
        let bytes = include_bytes!("../../../libavif-c/tests/data/io/kodim03_yuv420_8bpc.avif");
        let decoder = _init_memory_decoder(bytes.as_ptr(), bytes.len());
        let frame = _get_next_frame(decoder);
        assert!(frame.width > 0 && frame.height > 0);
        assert_eq!(frame.data.len(), (frame.width * frame.height * 4) as usize);
        _dispose_decoder(decoder);
    }

    #[test]
    fn animated_avif_all_frames_reset_and_release() {
        let bytes = include_bytes!("../../flutter_avif/example/assets/vettel.avif");
        let decoder = _init_memory_decoder(bytes.as_ptr(), bytes.len());
        let count = unsafe { (*decoder).imageCount };
        assert!(count > 1, "upstream fixture must be animated");
        let first = _get_next_frame(decoder);
        assert!(first.duration > 0.0);
        for _ in 1..count {
            let frame = _get_next_frame(decoder);
            assert_eq!((frame.width, frame.height), (first.width, first.height));
            assert_eq!(frame.data.len(), first.data.len());
            assert!(frame.duration > 0.0);
        }
        let looped = _get_next_frame(decoder);
        assert_eq!(looped.data, first.data);
        _reset_decoder(decoder);
        assert_eq!(_get_next_frame(decoder).data, first.data);
        _dispose_decoder(decoder);
    }
}
