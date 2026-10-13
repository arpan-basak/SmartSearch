# PDFBox can optionally decode JPEG 2000 images through Gemalto's decoder.
# Apex AI only extracts PDF text, so that optional image decoder is not
# included and R8 can safely ignore the reference.
-dontwarn com.gemalto.jp2.JP2Decoder

# ONNX Runtime's Java API crosses JNI and must retain its native entry points
# in optimized release builds.
-keep class ai.onnxruntime.** { *; }
-keepclassmembers class * {
    native <methods>;
}
