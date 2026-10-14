use native_animated_image_codec::decode_bytes;

#[test]
fn gif_apng_webp_keep_both_frames_and_timing() {
    let inputs: &[&[u8]] = &[
        include_bytes!("ohos-fixtures/two-frames.gif"),
        include_bytes!("ohos-fixtures/two-frames.png"),
        include_bytes!("ohos-fixtures/two-frames.webp"),
    ];
    for bytes in inputs {
        let image = decode_bytes(bytes).expect("decode two-frame animation");
        assert_eq!((image.width, image.height), (2, 2));
        assert_eq!(image.frames.len(), 2);
        assert_eq!(image.loop_count, 0);
        assert_eq!(image.frames[0].delay_ms, 100);
        assert_eq!(image.frames[1].delay_ms, 200);
        assert_eq!(image.frames[0].rgba, [255, 0, 0, 255].repeat(4));
        assert_eq!(image.frames[1].rgba, [0, 0, 255, 255].repeat(4));
    }
}
