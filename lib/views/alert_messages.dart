import 'package:monitoring_driver/services/tts_service.dart';

class AlertMessages {
  const AlertMessages._();

  static String _pick(
    AlertLang lang, {
    required String en,
    required String hi,
    required String ml,
    required String ta,
    required String kn,
  }) {
    switch (lang) {
      case AlertLang.hindi:
        return hi;
      case AlertLang.malayalam:
        return ml;
      case AlertLang.tamil:
        return ta;
      case AlertLang.kannada:
        return kn;
      case AlertLang.english:
        return en;
    }
  }

  static String verifyFace(AlertLang lang) => _pick(
    lang,
    en: 'Please verify your face before starting.',
    hi: 'शुरू करने से पहले कृपया अपना चेहरा सत्यापित करें।',
    ml: 'ആരംഭിക്കുന്നതിന് മുമ്പ് ദയവായി നിങ്ങളുടെ മുഖം പരിശോധിക്കുക.',
    ta: 'தொடங்குவதற்கு முன் உங்கள் முகத்தைச் சரிபார்க்கவும்.',
    kn: 'ಪ್ರಾರಂಭಿಸುವ ಮೊದಲು ದಯವಿಟ್ಟು ನಿಮ್ಮ ಮುಖವನ್ನು ಪರಿಶೀಲಿಸಿ.',
  );

  static String welcome(AlertLang lang, String name) => _pick(
    lang,
    en: 'Welcome $name. Identity verified.',
    hi: 'स्वागत है $name। पहचान सत्यापित हो गई।',
    ml: 'സ്വാഗതം $name. തിരിച്ചറിയൽ പൂർത്തിയായി.',
    ta: 'வரவேற்கிறோம் $name. அடையாளம் சரிபார்க்கப்பட்டது.',
    kn: 'ಸ್ವಾಗತ $name. ಗುರುತು ಪರಿಶೀಲಿಸಲಾಗಿದೆ.',
  );

  static String phone(AlertLang lang) => _pick(
    lang,
    en: 'Phone usage detected. Please avoid using your phone while driving.',
    hi: 'कृपया गाड़ी चलाते समय फोन का उपयोग न करें।',
    ml: 'വാഹനം ഓടിക്കുമ്പോൾ ഫോൺ ഉപയോഗിക്കരുത്.',
    ta: 'ஓட்டும்போது ஃபோனைப் பயன்படுத்த வேண்டாம்.',
    kn: 'ವಾಹನ ಚಾಲನೆ ಮಾಡುವಾಗ ಫೋನ್ ಬಳಸಬೇಡಿ.',
  );

  static String cigarette(AlertLang lang) => _pick(
    lang,
    en: 'Smoking detected.',
    hi: 'गाड़ी चलाते समय धूम्रपान न करें।',
    ml: 'വാഹനം ഓടിക്കുമ്പോൾ പുകവലിക്കരുത്.',
    ta: 'ஓட்டும்போது புகைபிடிக்க வேண்டாம்.',
    kn: 'ವಾಹನ ಚಾಲನೆ ಮಾಡುವಾಗ ಧೂಮಪಾನ ಮಾಡಬೇಡಿ.',
  );

  static String eating(AlertLang lang) => _pick(
    lang,
    en: 'Please do not eat while driving.',
    hi: 'कृपया गाड़ी चलाते समय भोजन न करें।',
    ml: 'വാഹനം ഓടിക്കുമ്പോൾ ഭക്ഷണം കഴിക്കരുത്.',
    ta: 'ஓட்டும்போது சாப்பிட வேண்டாம்.',
    kn: 'ವಾಹನ ಚಾಲನೆ ಮಾಡುವಾಗ ತಿನ್ನಬೇಡಿ.',
  );

  static String drinking(AlertLang lang) => _pick(
    lang,
    en: 'Please do not drink while driving.',
    hi: 'कृपया गाड़ी चलाते समय कुछ न पिएं।',
    ml: 'വാഹനം ഓടിക്കുമ്പോൾ കുടിക്കരുത്.',
    ta: 'ஓட்டும்போது குடிக்க வேண்டாம்.',
    kn: 'ವಾಹನ ಚಾಲನೆ ಮಾಡುವಾಗ ಕುಡಿಯಬೇಡಿ.',
  );

  static String unauthorized(AlertLang lang) => _pick(
    lang,
    en: 'Driver change detected.',
    hi: 'चालक परिवर्तन का पता चला।',
    ml: 'ഡ്രൈവർ മാറ്റം കണ്ടെത്തി.',
    ta: 'ஓட்டுநர் மாற்றம் கண்டறியப்பட்டது.',
    kn: 'ചಾಲക ಬದಲಾವಣೆ ಪತ್ತೆಯಾಗಿದೆ.',
  );

  // static String noDriverDetected(AlertLang lang) => _pick(
  //   lang,
  //   en: 'Driver not detected.',
  //   hi: 'चालक का पता नहीं चला।',
  //   ml: 'ഡ്രൈവറെ കണ്ടെത്തിയില്ല.',
  //   ta: 'ஓட்டுநர் கண்டறியப்படவில்லை.',
  //   kn: 'ಚಾಲಕ ಪತ್ತೆಯಾಗಿಲ್ಲ.',
  // );

  static String unverifiedDriver(AlertLang lang) => _pick(
    lang,
    en: 'Driver not verified. Please verify your face before driving.',
    hi: 'चालक सत्यापित नहीं है। कृपया गाड़ी चलाने से पहले अपना चेहरा सत्यापित करें।',
    ml: 'ഡ്രൈവർ പരിശോധിച്ചിട്ടില്ല. വാഹനം ഓടിക്കുന്നതിന് മുമ്പ് മുഖം പരിശോധിക്കുക.',
    ta: 'ஓட்டுநர் சரிபார்க்கப்படவில்லை. ஓட்டுவதற்கு முன் முகத்தைச் சரிபார்க்கவும்.',
    kn: 'ಚಾಲಕ ಪರಿಶೀಲಿಸಲಾಗಿಲ್ಲ. ವಾಹನ ಚಾಲನೆ ಮಾಡುವ ಮೊದಲು ಮುಖ ಪರಿಶೀಲಿಸಿ.',
  );

  static String drowsy(AlertLang lang) => _pick(
    lang,
    en: 'Drowsiness detected. Please stay alert.',
    hi: 'आप थके हुए लग रहे हैं। कृपया सतर्क रहें।',
    ml: 'നിങ്ങൾ ക്ഷീണിതനായി കാണപ്പെടുന്നു. ജാഗ്രത പാലിക്കുക.',
    ta: 'நீங்கள் சோர்வாக இருக்கிறீர்கள். எச்சரிக்கையாக இருங்கள்.',
    kn: 'ನೀವು ಆಯಾಸವಾಗಿ ಕಾಣುತ್ತಿದ್ದೀರಿ. ದಯವಿಟ್ಟು ಎಚ್ಚರವಾಗಿರಿ.',
  );

  static String distraction(AlertLang lang) => _pick(
    lang,
    en: 'Driver distraction detected. Please focus on the road.',
    hi: 'कृपया अपनी नज़र सड़क पर रखें।',
    ml: 'ദയവായി റോഡിൽ ശ്രദ്ധിക്കുക.',
    ta: 'சாலையில் கவனம் செலுத்துங்கள்.',
    kn: 'ದಯವಿಟ್ಟು ರಸ್ತೆಯ ಮೇಲೆ ಗಮನ ಇಡಿ.',
  );

  static String overspeed(AlertLang lang) => _pick(
    lang,
    en: 'Overspeeding detected. Reduce speed.',
    hi: 'तेज़ गति का पता चला। गति कम करें।',
    ml: 'അമിതവേഗത കണ്ടെത്തി. വേഗത കുറയ്ക്കുക.',
    ta: 'அதிவேகம் கண்டறியப்பட்டது. வேகத்தைக் குறைக்கவும்.',
    kn: 'ಅತಿವೇಗ ಪತ್ತೆಯಾಗಿದೆ. ವೇಗ ಕಡಿಮೆ ಮಾಡಿ.',
  );

  static String seatbelt(AlertLang lang) => _pick(
    lang,
    en: 'Please wear your seatbelt.',
    hi: 'सीट बेल्ट नहीं लगी है। कृपया सीट बेल्ट लगाएं।',
    ml: 'സീറ്റ് ബെൽറ്റ് ധരിച്ചിട്ടില്ല. ദയവായി സീറ്റ് ബെൽറ്റ് ധരിക്കുക.',
    ta: 'சீட் பெல்ட் அணியவில்லை. சீட் பெல்ட்டை அணியுங்கள்.',
    kn: 'ಸೀಟ್ ಬೆಲ್ಟ್ ಪತ್ತೆಯಾಗಿಲ್ಲ. ದಯವಿಟ್ಟು ಸೀಟ್ ಬೆಲ್ಟ್ ಧರಿಸಿ.',
  );

  static String personDetected(AlertLang lang) => _pick(
    lang,
    en: 'Warning. Person detected.',
    hi: 'चेतावनी। व्यक्ति का पता चला।',
    ml: 'മുന്നറിയിപ്പ്. വ്യക്തിയെ കണ്ടെത്തി.',
    ta: 'எச்சரிக்கை. நபர் கண்டறியப்பட்டார்.',
    kn: 'ಎಚ್ಚರಿಕೆ. ವ್ಯಕ್ತಿ ಪತ್ತೆಯಾಗಿದೆ.',
  );

  static String vehicleDetected(AlertLang lang) => _pick(
    lang,
    en: 'Warning. Vehicle detected.',
    hi: 'चेतावनी। वाहन का पता चला।',
    ml: 'മുന്നറിയിപ്പ്. വാഹനത്തെ കണ്ടെത്തി.',
    ta: 'எச்சரிக்கை. வாகனம் கண்டறியப்பட்டது.',
    kn: 'ಎಚ್ಚರಿಕೆ. ವಾಹನ ಪತ್ತೆಯಾಗಿದೆ.',
  );

  static String harshBraking(AlertLang lang) => _pick(
    lang,
    en: 'Please brake gently.',
    hi: 'कृपया धीरे से ब्रेक लगाएं।',
    ml: 'ദയവായി സാവധാനത്തിൽ ബ്രേക്ക് ചെയ്യുക.',
    ta: 'மெதுவாக பிரேக் செய்யவும்.',
    kn: 'ದಯವಿಟ್ಟು ನಿಧಾನವಾಗಿ ಬ್ರೇಕ್ ಹಾಕಿ.',
  );

  static String harshAcceleration(AlertLang lang) => _pick(
    lang,
    en: 'Please accelerate smoothly.',
    hi: 'कृपया धीरे-धीरे गति बढ़ाएं।',
    ml: 'ദയവായി സാവധാനത്തിൽ വേഗത കൂട്ടുക.',
    ta: 'மெதுவாக வேகத்தை அதிகரிக்கவும்.',
    kn: 'ದಯವಿಟ್ಟು ನಿಧಾನವಾಗಿ ವೇಗ ಹೆಚ್ಚಿಸಿ.',
  );

  static String boundaryViolation(AlertLang lang) => _pick(
    lang,
    en: 'Warning. You have crossed the boundary limit.',
    hi: 'चेतावनी। आपने सीमा पार कर ली है।',
    ml: 'മുന്നറിയിപ്പ്. നിങ്ങൾ അതിർത്തി കടന്നിരിക്കുന്നു.',
    ta: 'எச்சரிக்கை. நீங்கள் எல்லையை தாண்டிவிட்டீர்கள்.',
    kn: 'ಎಚ್ಚರಿಕೆ. ನೀವು ಗಡಿ ಮೀರಿದ್ದೀರಿ.',
  );

  static String motorcycleDetected(AlertLang lang) => _pick(
    lang,
    en: 'Warning. Motorcycle detected.',
    hi: 'चेतावनी। मोटरसाइकिल का पता चला।',
    ml: 'മുന്നറിയിപ്പ്. മോട്ടോർസൈക്കിൾ കണ്ടെത്തി.',
    ta: 'எச்சரிக்கை. இருசக்கர வாகனம் கண்டறியப்பட்டது.',
    kn: 'ಎಚ್ಚರಿಕೆ. ಮೋಟಾರ್‌ಸೈಕಲ್ ಪತ್ತೆಯಾಗಿದೆ.',
  );

  static String busDetected(AlertLang lang) => _pick(
    lang,
    en: 'Warning. Bus detected.',
    hi: 'चेतावनी। बस का पता चला।',
    ml: 'മുന്നറിയിപ്പ്. ബസ് കണ്ടെത്തി.',
    ta: 'எச்சரிக்கை. பேருந்து கண்டறியப்பட்டது.',
    kn: 'ಎಚ್ಚರಿಕೆ. ಬಸ್ ಪತ್ತೆಯಾಗಿದೆ.',
  );

  static String bicycleDetected(AlertLang lang) => _pick(
    lang,
    en: 'Warning. Bicycle detected.',
    hi: 'चेतावनी। साइकिल का पता चला।',
    ml: 'മുന്നറിയിപ്പ്. സൈക്കിൾ കണ്ടെത്തി.',
    ta: 'எச்சரிக்கை. மிதிவண்டி கண்டறியப்பட்டது.',
    kn: 'ಎಚ್ಚರಿಕೆ. ಬೈಸಿಕಲ್ ಪತ್ತೆಯಾಗಿದೆ.',
  );

  static String truckDetected(AlertLang lang) => _pick(
    lang,
    en: 'Warning. Truck detected.',
    hi: 'चेतावनी। ट्रक का पता चला।',
    ml: 'മുന്നറിയിപ്പ്. ട്രക്ക് കണ്ടെത്തി.',
    ta: 'எச்சரிக்கை. லாரி கண்டறியப்பட்டது.',
    kn: 'ಎಚ್ಚರಿಕೆ. ಟ್ರಕ್ ಪತ್ತೆಯಾಗಿದೆ.',
  );

  /// Break reminder messages
  static String breakReminder(AlertLang lang, int index) {
    switch (index % 2) {
      case 0:
        return _pick(
          lang,
          en: 'Stay Hydrated! Drink some water to stay alert and focused.',
          hi: 'हाइड्रेटेड रहें! सतर्क रहने के लिए कुछ पानी पिएं।',
          ml: 'വെള്ളം കുടിക്കുക! ശ്രദ്ധയോടെ ഇരിക്കാൻ കുറച്ച് വെള്ളം കുടിക്കുക.',
          ta: 'நீரேற்றமாக இருங்கள்! கவனமாக இருக்க கொஞ்சம் தண்ணீர் குடியுங்கள்.',
          kn: 'ನೀರು ಕುಡಿಯಿರಿ! ಎಚ್ಚರವಾಗಿರಲು ಸ್ವಲ್ಪ ನೀರು ಕುಡಿಯಿರಿ.',
        );
      case 1:
      default:
        return _pick(
          lang,
          en: 'Take a Deep Breath. Breathe deeply to reduce stress and stay calm.',
          hi: 'गहरी सांस लें। तनाव कम करने और शांत रहने के लिए गहरी सांस लें।',
          ml: 'ആഴത്തിൽ ശ്വസിക്കുക. സമ്മർദ്ദം കുറയ്ക്കാനും ശാന്തമായി ഇരിക്കാനും ആഴത്തിൽ ശ്വസിക്കുക.',
          ta: 'ஆழமாக சுவாசியுங்கள். மன அழுத்தத்தை குறைக்க ஆழமாக சுவாசிக்கவும்.',
          kn: 'ಆಳವಾಗಿ ಉಸಿರಾಡಿ. ಒತ್ತಡ ಕಡಿಮೆ ಮಾಡಲು ಆಳವಾಗಿ ಉಸಿರಾಡಿ.',
        );
    }
  }

  static String licenseExpired(AlertLang lang) => _pick(
    lang,
    en: 'Your driving license has expired. Trip cannot be started. Please renew your license.',
    hi: 'आपका ड्राइविंग लाइसेंस समाप्त हो गया है। यात्रा शुरू नहीं की जा सकती। कृपया अपना लाइसेंस नवीनीकृत करें।',
    ml: 'നിങ്ങളുടെ ഡ്രൈവിംഗ് ലൈസൻസ് കാലഹരണപ്പെട്ടു. യാത്ര ആരംഭിക്കാൻ കഴിയില്ല. ദയവായി ലൈസൻസ് പുതുക്കുക.',
    ta: 'உங்கள் ஓட்டுநர் உரிமம் காலாவதியானது. பயணத்தை தொடங்க முடியாது. உரிமத்தை புதுப்பிக்கவும்.',
    kn: 'ನಿಮ್ಮ ಚಾಲನಾ ಪರವಾನಗಿ ಅವಧಿ ಮುಗಿದಿದೆ. ಪ್ರಯಾಣ ಪ್ರಾರಂಭಿಸಲು ಸಾಧ್ಯವಿಲ್ಲ. ದಯವಿಟ್ಟು ಪರವಾನಗಿ ನವೀಕರಿಸಿ.',
  );

  static String licenseExpiringSoon(AlertLang lang, int daysLeft) => _pick(
    lang,
    en: daysLeft == 0
        ? 'Warning. Your driving license expires today. Please renew immediately.'
        : 'Warning. Your driving license expires in $daysLeft day${daysLeft == 1 ? '' : 's'}. Please renew soon.',
    hi: daysLeft == 0
        ? 'चेतावनी। आपका ड्राइविंग लाइसेंस आज समाप्त हो रहा है। कृपया तुरंत नवीनीकृत करें।'
        : 'चेतावनी। आपका ड्राइविंग लाइसेंस $daysLeft दिन${daysLeft == 1 ? '' : 'ों'} में समाप्त हो रहा है। कृपया जल्द नवीनीकृत करें।',
    ml: daysLeft == 0
        ? 'മുന്നറിയിപ്പ്. നിങ്ങളുടെ ഡ്രൈവിംഗ് ലൈസൻസ് ഇന്ന് കാലഹരണപ്പെടുന്നു. ഉടനടി പുതുക്കുക.'
        : 'മുന്നറിയിപ്പ്. നിങ്ങളുടെ ഡ്രൈവിംഗ് ലൈസൻസ് $daysLeft ദിവസത്തിനുള്ളിൽ കാലഹരണപ്പെടും. ഉടനെ പുതുക്കുക.',
    ta: daysLeft == 0
        ? 'எச்சரிக்கை. உங்கள் ஓட்டுநர் உரிமம் இன்று காலாவதியாகிறது. உடனே புதுப்பிக்கவும்.'
        : 'எச்சரிக்கை. உங்கள் ஓட்டுநர் உரிமம் $daysLeft நாள${daysLeft == 1 ? '' : 'களி'}ல் காலாவதியாகும். விரைவில் புதுப்பிக்கவும்.',
    kn: daysLeft == 0
        ? 'ಎಚ್ಚರಿಕೆ. ನಿಮ್ಮ ಚಾಲನಾ ಪರವಾನಗಿ ಇಂದು ಅವಧಿ ಮುಗಿಯುತ್ತದೆ. ತಕ್ಷಣ ನವೀಕರಿಸಿ.'
        : 'ಎಚ್ಚರಿಕೆ. ನಿಮ್ಮ ಚಾಲನಾ ಪರವಾನಗಿ $daysLeft ದಿನಗಳಲ್ಲಿ ಅವಧಿ ಮುಗಿಯುತ್ತದೆ. ಶೀಘ್ರದಲ್ಲೇ ನವೀಕರಿಸಿ.',
  );
}
