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

  static String verifyFace(AlertLang lang) => _pick(lang,
      en: 'Please verify your face before starting.',
      hi: 'शुरू करने से पहले कृपया अपना चेहरा सत्यापित करें।',
      ml: 'ആരംഭിക്കുന്നതിന് മുമ്പ് ദയവായി നിങ്ങളുടെ മുഖം പരിശോധിക്കുക.',
      ta: 'தொடங்குவதற்கு முன் உங்கள் முகத்தைச் சரிபார்க்கவும்.');

  static String welcome(AlertLang lang, String name) => _pick(lang,
      en: 'Welcome $name. Identity verified.',
      hi: '$name का स्वागत है। पहचान सत्यापित हो गई।',
      ml: '$name-നു സ്വാഗതം. തിരിച്ചറിയൽ പൂർത്തിയായി.',
      ta: '$name வரவேற்கிறோம். அடையாளம் சரிபார்க்கப்பட்டது.');

  static String phone(AlertLang lang) => _pick(lang,
      en: 'Please avoid phone while driving.',
      hi: 'कृपया गाड़ी चलाते समय फोन का उपयोग न करें।',
      ml: 'വാഹനം ഓടിക്കുമ്പോൾ ഫോൺ ഉപയോഗിക്കരുത്.',
      ta: 'ஓட்டும்போது ஃபோனைப் பயன்படுத்த வேண்டாம்.');

  static String cigarette(AlertLang lang) => _pick(lang,
      en: 'No smoking while driving.',
      hi: 'गाड़ी चलाते समय धूम्रपान न करें।',
      ml: 'വാഹനം ഓടിക്കുമ്പോൾ പുകവലിക്കരുത്.',
      ta: 'ஓட்டும்போது புகைபிடிக்க வேண்டாம்.');

  static String eating(AlertLang lang) => _pick(lang,
      en: 'Please do not eat while driving.',
      hi: 'कृपया गाड़ी चलाते समय भोजन न करें।',
      ml: 'വാഹനം ഓടിക്കുമ്പോൾ ഭക്ഷണം കഴിക്കരുത്.',
      ta: 'ஓட்டும்போது சாப்பிட வேண்டாம்.');

  static String drinking(AlertLang lang) => _pick(lang,
      en: 'Please do not drink while driving.',
      hi: 'कृपया गाड़ी चलाते समय कुछ न पिएं।',
      ml: 'വാഹനം ഓടിക്കുമ്പോൾ കുടിക്കരുത്.',
      ta: 'ஓட்டும்போது குடிக்க வேண்டாம்.');

 static String unauthorized(AlertLang lang) => _pick(lang,
    en: 'Unauthorized driver detected.',
    hi: 'अनधिकृत चालक का पता चला।',
    ml: 'അനധികൃത ഡ്രൈവറെ കണ്ടെത്തി.',
    ta: 'அங்கீகரிக்கப்படாத ஓட்டுநர் கண்டறியப்பட்டார்.');

  static String drowsy(AlertLang lang) => _pick(lang,
      en: 'You appear tired. Please stay alert.',
      hi: 'आप थके हुए लग रहे हैं। कृपया सतर्क रहें।',
      ml: 'നിങ്ങൾ ക്ഷീണിതനായി കാണപ്പെടുന്നു. ജാഗ്രത പാലിക്കുക.',
      ta: 'நீங்கள் சோர்வாக இருக்கிறீர்கள். எச்சரிக்கையாக இருங்கள்.');

  static String distraction(AlertLang lang) => _pick(lang,
      en: 'Please keep your eyes on the road.',
      hi: 'कृपया अपनी नज़र सड़क पर रखें।',
      ml: 'ദയവായി റോഡിൽ ശ്രദ്ധിക്കുക.',
      ta: 'சாலையில் கவனம் செலுத்துங்கள்.');

  static String overspeed(AlertLang lang) => _pick(lang,
      en: 'Overspeeding detected. Reduce speed.',
      hi: 'तेज़ गति का पता चला। गति कम करें।',
      ml: 'അമിതവേഗത കണ്ടെത്തി. വേഗത കുറയ്ക്കുക.',
      ta: 'அதிவேகம் கண்டறியப்பட்டது. வேகத்தைக் குறைக்கவும்.');

  static String seatbelt(AlertLang lang) => _pick(lang,
      en: 'Seat belt not detected. Please wear your seat belt.',
      hi: 'सीट बेल्ट नहीं लगी है। कृपया सीट बेल्ट लगाएं।',
      ml: 'സീറ്റ് ബെൽറ്റ് ധരിച്ചിട്ടില്ല. ദയവായി സീറ്റ് ബെൽറ്റ് ധരിക്കുക.',
      ta: 'சீட் பெல்ட் அணியவில்லை. சீட் பெல்ட்டை அணியுங்கள்.');

  static String personDetected(AlertLang lang) => _pick(lang,
      en: 'Warning. Person detected.',
      hi: 'चेतावनी। व्यक्ति का पता चला।',
      ml: 'മുന്നറിയിപ്പ്. വ്യക്തിയെ കണ്ടെത്തി.',
      ta: 'எச்சரிக்கை. நபர் கண்டறியப்பட்டார்.');

  static String vehicleDetected(AlertLang lang) => _pick(lang,
      en: 'Warning. Vehicle detected.',
      hi: 'चेतावनी। वाहन का पता चला।',
      ml: 'മുന്നറിയിപ്പ്. വാഹനത്തെ കണ്ടെത്തി.',
      ta: 'எச்சரிக்கை. வாகனம் கண்டறியப்பட்டது.');
}