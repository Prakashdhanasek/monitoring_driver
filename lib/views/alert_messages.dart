import 'package:monitoring_driver/services/tts_service.dart';

class AlertMessages {
  const AlertMessages._();

  static String _pick(
    AlertLang lang, {
    required String en,
    required String hi,
    required String ml,
    required String ta,
  }) {
    switch (lang) {
      case AlertLang.hindi:
        return hi;
      case AlertLang.malayalam:
        return ml;
      case AlertLang.tamil:
        return ta;
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
  );

  static String welcome(AlertLang lang, String name) => _pick(
    lang,
    en: 'Welcome $name. Identity verified.',
    hi: 'स्वागत है $name। पहचान सत्यापित हो गई।',
    ml: 'സ്വാഗതം $name. തിരിച്ചറിയൽ പൂർത്തിയായി.',
    ta: 'வரவேற்கிறோம் $name. அடையாளம் சரிபார்க்கப்பட்டது.',
  );

  static String phone(AlertLang lang) => _pick(
    lang,
    en: 'Please avoid phone while driving.',
    hi: 'कृपया गाड़ी चलाते समय फोन का उपयोग न करें।',
    ml: 'വാഹനം ഓടിക്കുമ്പോൾ ഫോൺ ഉപയോഗിക്കരുത്.',
    ta: 'ஓட்டும்போது ஃபோனைப் பயன்படுத்த வேண்டாம்.',
  );

  static String cigarette(AlertLang lang) => _pick(
    lang,
    en: 'No smoking while driving.',
    hi: 'गाड़ी चलाते समय धूम्रपान न करें।',
    ml: 'വാഹനം ഓടിക്കുമ്പോൾ പുകവലിക്കരുത്.',
    ta: 'ஓட்டும்போது புகைபிடிக்க வேண்டாம்.',
  );

  static String eating(AlertLang lang) => _pick(
    lang,
    en: 'Please do not eat while driving.',
    hi: 'कृपया गाड़ी चलाते समय भोजन न करें।',
    ml: 'വാഹനം ഓടിക്കുമ്പോൾ ഭക്ഷണം കഴിക്കരുത്.',
    ta: 'ஓட்டும்போது சாப்பிட வேண்டாம்.',
  );

  static String drinking(AlertLang lang) => _pick(
    lang,
    en: 'Please do not drink while driving.',
    hi: 'कृपया गाड़ी चलाते समय कुछ न पिएं।',
    ml: 'വാഹനം ഓടിക്കുമ്പോൾ കുടിക്കരുത്.',
    ta: 'ஓட்டும்போது குடிக்க வேண்டாம்.',
  );

  static String unauthorized(AlertLang lang) => _pick(
    lang,
    en: 'Unauthorized driver detected.',
    hi: 'अनधिकृत चालक का पता चला।',
    ml: 'അനധികൃത ഡ്രൈവറെ കണ്ടെത്തി.',
    ta: 'அங்கீகரிக்கப்படாத ஓட்டுநர் கண்டறியப்பட்டார்.',
  );

  static String unverifiedDriver(AlertLang lang) => _pick(
    lang,
    en: 'Driver not verified. Please verify your face before driving.',
    hi: 'चालक सत्यापित नहीं है। कृपया गाड़ी चलाने से पहले अपना चेहरा सत्यापित करें।',
    ml: 'ഡ്രൈവർ പരിശോധിച്ചിട്ടില്ല. വാഹനം ഓടിക്കുന്നതിന് മുമ്പ് മുഖം പരിശോധിക്കുക.',
    ta: 'ஓட்டுநர் சரிபார்க்கப்படவில்லை. ஓட்டுவதற்கு முன் முகத்தைச் சரிபார்க்கவும்.',
  );

  static String drowsy(AlertLang lang) => _pick(
    lang,
    en: 'You appear tired. Please stay alert.',
    hi: 'आप थके हुए लग रहे हैं। कृपया सतर्क रहें।',
    ml: 'നിങ്ങൾ ക്ഷീണിതനായി കാണപ്പെടുന്നു. ജാഗ്രത പാലിക്കുക.',
    ta: 'நீங்கள் சோர்வாக இருக்கிறீர்கள். எச்சரிக்கையாக இருங்கள்.',
  );

  static String distraction(AlertLang lang) => _pick(
    lang,
    en: 'Please keep your eyes on the road.',
    hi: 'कृपया अपनी नज़र सड़क पर रखें।',
    ml: 'ദയവായി റോഡിൽ ശ്രദ്ധിക്കുക.',
    ta: 'சாலையில் கவனம் செலுத்துங்கள்.',
  );

  static String overspeed(AlertLang lang) => _pick(
    lang,
    en: 'Overspeeding detected. Reduce speed.',
    hi: 'तेज़ गति का पता चला। गति कम करें।',
    ml: 'അമിതവേഗത കണ്ടെത്തി. വേഗത കുറയ്ക്കുക.',
    ta: 'அதிவேகம் கண்டறியப்பட்டது. வேகத்தைக் குறைக்கவும்.',
  );

  static String seatbelt(AlertLang lang) => _pick(
    lang,
    en: 'Seat belt not detected. Please wear your seat belt.',
    hi: 'सीट बेल्ट नहीं लगी है। कृपया सीट बेल्ट लगाएं।',
    ml: 'സീറ്റ് ബെൽറ്റ് ധരിച്ചിട്ടില്ല. ദയവായി സീറ്റ് ബെൽറ്റ് ധരിക്കുക.',
    ta: 'சீட் பெல்ட் அணியவில்லை. சீட் பெல்ட்டை அணியுங்கள்.',
  );

  static String personDetected(AlertLang lang) => _pick(
    lang,
    en: 'Warning. Person detected.',
    hi: 'चेतावनी। व्यक्ति का पता चला।',
    ml: 'മുന്നറിയിപ്പ്. വ്യക്തിയെ കണ്ടെത്തി.',
    ta: 'எச்சரிக்கை. நபர் கண்டறியப்பட்டார்.',
  );

  static String vehicleDetected(AlertLang lang) => _pick(
    lang,
    en: 'Warning. Vehicle detected.',
    hi: 'चेतावनी। वाहन का पता चला।',
    ml: 'മുന്നറിയിപ്പ്. വാഹനത്തെ കണ്ടെത്തി.',
    ta: 'எச்சரிக்கை. வாகனம் கண்டறியப்பட்டது.',
  );

  static String harshBraking(AlertLang lang) => _pick(
    lang,
    en: 'Please brake gently.',
    hi: 'कृपया धीरे से ब्रेक लगाएं।',
    ml: 'ദയവായി സാവധാനത്തിൽ ബ്രേക്ക് ചെയ്യുക.',
    ta: 'மெதுவாக பிரேக் செய்யவும்.',
  );

  static String harshAcceleration(AlertLang lang) => _pick(
    lang,
    en: 'Please accelerate smoothly.',
    hi: 'कृपया धीरे-धीरे गति बढ़ाएं।',
    ml: 'ദയവായി സാവധാനത്തിൽ വേഗത കൂട്ടുക.',
    ta: 'மெதுவாக வேகத்தை அதிகரிக்கவும்.',
  );

  static String boundaryViolation(AlertLang lang) => _pick(
    lang,
    en: 'Warning. You have crossed the boundary limit.',
    hi: 'चेतावनी। आपने सीमा पार कर ली है।',
    ml: 'മുന്നറിയിപ്പ്. നിങ്ങൾ അതിർത്തി കടന്നിരിക്കുന്നു.',
    ta: 'எச்சரிக்கை. நீங்கள் எல்லையை தாண்டிவிட்டீர்கள்.',
  );

  static String motorcycleDetected(AlertLang lang) => _pick(
    lang,
    en: 'Warning. Motorcycle detected.',
    hi: 'चेतावनी। मोटरसाइकिल का पता चला।',
    ml: 'മുന്നറിയിപ്പ്. മോട്ടോർസൈക്കിൾ കണ്ടെത്തി.',
    ta: 'எச்சரிக்கை. இருசக்கர வாகனம் கண்டறியப்பட்டது.',
  );

  static String busDetected(AlertLang lang) => _pick(
    lang,
    en: 'Warning. Bus detected.',
    hi: 'चेतावनी। बस का पता चला।',
    ml: 'മുന്നറിയിപ്പ്. ബസ് കണ്ടെത്തി.',
    ta: 'எச்சரிக்கை. பேருந்து கண்டறியப்பட்டது.',
  );

  static String bicycleDetected(AlertLang lang) => _pick(
    lang,
    en: 'Warning. Bicycle detected.',
    hi: 'चेतावनी। साइकिल का पता चला।',
    ml: 'മുന്നറിയിപ്പ്. സൈക്കിൾ കണ്ടെത്തി.',
    ta: 'எச்சரிக்கை. மிதிவண்டி கண்டறியப்பட்டது.',
  );

  static String truckDetected(AlertLang lang) => _pick(
    lang,
    en: 'Warning. Truck detected.',
    hi: 'चेतावनी। ट्रक का पता चला।',
    ml: 'മുന്നറിയിപ്പ്. ട്രക്ക് കണ്ടെത്തി.',
    ta: 'எச்சரிக்கை. லாரி கண்டறியப்பட்டது.',
  );

  /// Break reminder messages — rotates through 4 variations (index 0–3).
  static String breakReminder(AlertLang lang, int index) {
    switch (index % 2) {
      case 0:
        return _pick(
          lang,
          en: 'Stay Hydrated! Drink some water to stay alert and focused.',
          hi: 'हाइड्रेटेड रहें! सतर्क रहने के लिए कुछ पानी पिएं।',
          ml: 'വെള്ളം കുടിക്കുക! ശ്രദ്ധയോടെ ഇരിക്കാൻ കുറച്ച് വെള്ളം കുടിക്കുക.',
          ta: 'நீரேற்றமாக இருங்கள்! கவனமாக இருக்க கொஞ்சம் தண்ணீர் குடியுங்கள்.',
        );
      case 1:
      default:
        return _pick(
          lang,
          en: 'Take a Deep Breath. Breathe deeply to reduce stress and stay calm.',
          hi: 'गहरी सांस लें। तनाव कम करने और शांत रहने के लिए गहरी सांस लें।',
          ml: 'ആഴത്തിൽ ശ്വസിക്കുക. സമ്മർദ്ദം കുറയ്ക്കാനും ശാന്തമായി ഇരിക്കാനും ആഴത്തിൽ ശ്വസിക്കുക.',
          ta: 'ஆழமாக சுவாசியுங்கள். மன அழுத்தத்தை குறைக்க ஆழமாக சுவாசிக்கவும்.',
        );
    }
  }

  static String licenseExpired(AlertLang lang) => _pick(
    lang,
    en: 'Your driving license has expired. Trip cannot be started. Please renew your license.',
    hi: 'आपका ड्राइविंग लाइसेंस समाप्त हो गया है। यात्रा शुरू नहीं की जा सकती। कृपया अपना लाइसेंस नवीनीकृत करें।',
    ml: 'നിങ്ങളുടെ ഡ്രൈവിംഗ് ലൈസൻസ് കാലഹരണപ്പെട്ടു. യാത്ര ആരംഭിക്കാൻ കഴിയില്ല. ദയവായി ലൈസൻസ് പുതുക്കുക.',
    ta: 'உங்கள் ஓட்டுநர் உரிமம் காலாவதியானது. பயணத்தை தொடங்க முடியாது. உரிமத்தை புதுப்பிக்கவும்.',
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
  );
}
