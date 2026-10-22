group = "com.linh18nd.flutter_live2d"
version = "1.0.2"

buildscript {
    val kotlinVersion = "2.2.20"
    repositories {
        google()
        mavenCentral()
    }

    dependencies {
        classpath("com.android.tools.build:gradle:8.11.1")
        classpath("org.jetbrains.kotlin:kotlin-gradle-plugin:$kotlinVersion")
    }
}

allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

plugins {
    id("com.android.library")
    id("kotlin-android")
}

// Cubism loads these via Android's AssetManager, outside Flutter's asset bundle.
// Preserve the SDK filenames and directory exactly; no character assets belong here.
// Android's legacy SourceSet API rejects Providers on AGP 9. Resolve the shared
// directory once and wire its producer explicitly through preBuild below.
val generatedLive2dAssetsDir = layout.buildDirectory.dir("generated/live2dAssets").get().asFile
val prepareFrameworkShaders by tasks.registering(Sync::class) {
    // Standard is desktop GLSL 1.20; an Android ES2 context requires StandardES.
    // Include the Tegra variants selected by the SDK on affected devices too.
    from("src/main/cpp/CubismFramework/Rendering/OpenGL/Shaders/StandardES")
    into(generatedLive2dAssetsDir.resolve("FrameworkShaders"))
    include("*.vert", "*.frag")
}

tasks.named("preBuild").configure { dependsOn(prepareFrameworkShaders) }

android {
    namespace = "com.linh18nd.flutter_live2d"

    compileSdk = 36

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    sourceSets {
        getByName("main") {
            java.srcDirs("src/main/kotlin")
            assets.srcDir(generatedLive2dAssetsDir)
        }
        getByName("test") {
            java.srcDirs("src/test/kotlin")
        }
    }

    defaultConfig {
        minSdk = 24
        // Match AgentAtelierR's native toolchain and its other Flutter plugins.
        ndkVersion = "28.2.13676358"

        externalNativeBuild {
            cmake {
                cppFlags("-std=c++14")
                arguments(
                    "-DANDROID_STL=c++_shared",
                    "-DANDROID_ARM_NEON=TRUE"
                )
                abiFilters("arm64-v8a", "x86_64")
            }
        }
    }

    externalNativeBuild {
        cmake {
            path = file("CMakeLists.txt")
            version = "3.22.1"
        }
    }

    packagingOptions {
        jniLibs {
            keepDebugSymbols += setOf("**/*.so")
        }
    }

    testOptions {
        unitTests {
            isIncludeAndroidResources = true
            all {
                it.useJUnitPlatform()

                it.outputs.upToDateWhen { false }

                it.testLogging {
                    events("passed", "skipped", "failed", "standardOut", "standardError")
                    showStandardStreams = true
                }
            }
        }
    }
}

dependencies {
    testImplementation("org.jetbrains.kotlin:kotlin-test")
    testImplementation("org.junit.jupiter:junit-jupiter:5.11.4")
    testImplementation("org.mockito:mockito-core:5.0.0")
}
