// Play Feature Delivery — module ON-DEMAND "translate": ML Kit Translation (native ~16 MB/arm64).
// App gốc không phụ thuộc ML Kit; module chỉ tải khi người dùng bấm "Tải tính năng Dịch".
plugins {
    id("com.android.dynamic-feature")
    id("org.jetbrains.kotlin.android")
}
android {
    namespace = "com.viettelex.android.translate"
    compileSdk = 36
    defaultConfig { minSdk = 26 }
    buildTypes { release { proguardFiles("proguard-rules.pro") } }
    compileOptions { sourceCompatibility = JavaVersion.VERSION_17; targetCompatibility = JavaVersion.VERSION_17 }
    kotlinOptions { jvmTarget = "17" }
}
dependencies {
    implementation(project(":app"))
    implementation(project(":keyboard"))
    implementation("com.google.mlkit:translate:17.0.3")
    testImplementation("junit:junit:4.13.2")
}
