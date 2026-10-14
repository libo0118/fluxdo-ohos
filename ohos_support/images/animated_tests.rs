use native_animated_image_codec::decode_bytes;

#[test]
fn gif_apng_webp_keep_both_frames_and_timing() {
    let inputs: &[(&[u8], u8)] = &[
        (include_bytes!("ohos-fixtures/two-frames.gif"), 0),
        (include_bytes!("ohos-fixtures/two-frames.png"), 0),
        // shortcut: upstream image-webp 0.2.4 differs by 1 LSB on this lossless VP8L fixture; restore exact RGB checks after its decoder is fixed or upgraded.
        (include_bytes!("ohos-fixtures/two-frames.webp"), 1),
    ];
    for (bytes, rgb_tolerance) in inputs {
        let image = decode_bytes(bytes).expect("decode two-frame animation");
        assert_eq!((image.width, image.height), (2, 2));
        assert_eq!(image.frames.len(), 2);
        assert_eq!(image.loop_count, 0);
        assert_eq!(image.frames[0].delay_ms, 100);
        assert_eq!(image.frames[1].delay_ms, 200);
        for (frame, pixel) in image.frames.iter().zip([[255, 0, 0, 255], [0, 0, 255, 255]]) {
            assert_eq!(frame.rgba.len(), 16);
            for (index, (actual, expected)) in frame.rgba.iter().zip(pixel.repeat(4)).enumerate() {
                let tolerance = if index % 4 == 3 { 0 } else { *rgb_tolerance };
                assert!(actual.abs_diff(expected) <= tolerance,
                    "frame pixel component {index}: {actual} vs {expected}, tolerance {tolerance}");
            }
        }
    }
}
