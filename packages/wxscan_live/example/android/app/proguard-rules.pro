# R8 will not finish a release build while a class it can see names one it
# cannot find, and okhttp - which arrives with large_file_handler, for the
# copy that keeps the weights out of Dart - names three TLS providers it uses
# when they happen to be present: BouncyCastle, Conscrypt and OpenJSSE. It
# looks for them at run time and does without them; none is on an Android
# application's classpath, and this application makes no network calls at all.
#
# These are the rules the Android Gradle plugin writes to
# build/app/outputs/mapping/release/missing_rules.txt when it stops.
-dontwarn org.bouncycastle.jsse.BCSSLParameters
-dontwarn org.bouncycastle.jsse.BCSSLSocket
-dontwarn org.bouncycastle.jsse.provider.BouncyCastleJsseProvider
-dontwarn org.conscrypt.Conscrypt$Version
-dontwarn org.conscrypt.Conscrypt
-dontwarn org.conscrypt.ConscryptHostnameVerifier
-dontwarn org.openjsse.javax.net.ssl.SSLParameters
-dontwarn org.openjsse.javax.net.ssl.SSLSocket
-dontwarn org.openjsse.net.ssl.OpenJSSE
