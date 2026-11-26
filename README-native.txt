Native apps source (teacher + student), Flutter. Public copy.
- Two entry points: lib/main_teacher.dart and lib/main_student.dart (flavors teacher/student, build with -Ptarget=lib/main_<flavor>.dart).
- lib/src/core.dart: kVodafoneCashNumber is a placeholder here; the real number is set in the private build.
- Font: assets/fonts/Cairo.ttf (not included here; add the Cairo font file from Google Fonts) registered in pubspec.yaml.
- Signing: android/app/key.properties is NOT included. Without it the build falls back to debug signing.
- Build: flutter pub get; cd android; ./gradlew assembleTeacherRelease -Ptarget=lib/main_teacher.dart (or assembleStudentRelease).
