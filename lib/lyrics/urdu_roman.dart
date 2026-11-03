// Byte © 2026 Apurba Laskar.
// Urdu (Arabic-script) lyrics in Roman letters, the way people type Hindi /
// Urdu songs in chats: "مجھ سے مل پائے گا نہیں" → "Mujh se mil paaye ga nahin".
// Urdu writes few vowels, so letter-by-letter reading loses them ("dl" for
// دل). A dictionary of common song words gives the spelling people expect;
// any other word is read by letter rules with the usual short "a" filled in.
// Pure Dart, unit tested.

/// True when [s] has Arabic-script letters (Urdu, Arabic, Persian, Kashmiri, Sindhi).
bool hasArabicLetters(String s) => s.runes.any(_isArabicLetter);

bool _isArabicLetter(int r) => (r >= 0x0620 && r <= 0x064A) || (r >= 0x066E && r <= 0x06D3) || (r >= 0x06FA && r <= 0x06FF) || (r >= 0x0750 && r <= 0x077F) || (r >= 0xFB50 && r <= 0xFDFF) || (r >= 0xFE70 && r <= 0xFEFF);

/// One spelling for letters that Urdu text types in several ways (Arabic
/// yeh / kaf / heh, joined presentation forms, vowel marks dropped).
String normalizeUrdu(String s) {
  final out = StringBuffer();
  for (final r in s.runes) {
    if ((r >= 0x064B && r <= 0x065F) || r == 0x0670 || r == 0x0640) continue; // harakat, superscript alef, tatweel
    out.write(switch (r) {
      0x064A || 0x0649 || 0x06D0 => 'ی',
      0x0643 => 'ک',
      0x0647 || 0x06D5 => 'ہ',
      0x06C2 => 'ہ',
      0x0629 => 'ہ',
      0x0623 || 0x0625 || 0x0671 => 'ا',
      0x200C || 0x200D || 0x200F || 0x200E => '',
      _ => String.fromCharCode(r),
    });
  }
  return out.toString();
}

/// Urdu punctuation as typed in Roman lyrics.
String _punct(String s) => s.replaceAll('،', ',').replaceAll('؟', '?').replaceAll('۔', '.').replaceAll('؛', ';').replaceAll('٪', '%');

/// Common words of Hindi / Urdu songs, in the spelling people type them.
const urduWords = <String, String>{
  'میں': 'main',
  'مَیں': 'main',
  'میرا': 'mera',
  'میری': 'meri',
  'میرے': 'mere',
  'مجھ': 'mujh',
  'مجھے': 'mujhe',
  'مجھکو': 'mujhko',
  'ہم': 'hum',
  'ہمیں': 'humein',
  'ہمارا': 'humara',
  'ہماری': 'humari',
  'ہمارے': 'humare',
  'ہمیشہ': 'hamesha',
  'تو': 'tu',
  'تُو': 'tu',
  'تم': 'tum',
  'تمہیں': 'tumhein',
  'تمھیں': 'tumhein',
  'تمہارا': 'tumhara',
  'تمہاری': 'tumhari',
  'تمہارے': 'tumhare',
  'تیرا': 'tera',
  'تیری': 'teri',
  'تیرے': 'tere',
  'تجھ': 'tujh',
  'تجھے': 'tujhe',
  'تجھکو': 'tujhko',
  'آپ': 'aap',
  'آپکا': 'aapka',
  'آپکی': 'aapki',
  'وہ': 'woh',
  'وو': 'woh',
  'یہ': 'ye',
  'اس': 'us',
  'اُس': 'us',
  'اِس': 'is',
  'ان': 'un',
  'اُن': 'un',
  'اِن': 'in',
  'انہیں': 'unhein',
  'اسے': 'use',
  'اسکا': 'uska',
  'اسکی': 'uski',
  'اسکے': 'uske',
  'کوئی': 'koi',
  'کچھ': 'kuch',
  'سب': 'sab',
  'سبھی': 'sabhi',
  'سارا': 'saara',
  'ساری': 'saari',
  'سارے': 'saare',
  'خود': 'khud',
  'اپنا': 'apna',
  'اپنی': 'apni',
  'اپنے': 'apne',
  'ہے': 'hai',
  'ہیں': 'hain',
  'ہوں': 'hoon',
  'ہو': 'ho',
  'ہوا': 'hua',
  'ہوئی': 'hui',
  'ہوئے': 'hue',
  'تھا': 'tha',
  'تھی': 'thi',
  'تھے': 'the',
  'تھیں': 'thin',
  'ہوگا': 'hoga',
  'ہوگی': 'hogi',
  'ہونگے': 'honge',
  'ہونا': 'hona',
  'ہوتا': 'hota',
  'ہوتی': 'hoti',
  'ہوتے': 'hote',
  'ہوکے': 'hoke',
  'ہوکر': 'hokar',
  'رہا': 'raha',
  'رہی': 'rahi',
  'رہے': 'rahe',
  'رہو': 'raho',
  'رہنا': 'rehna',
  'رہتا': 'rehta',
  'رہتی': 'rehti',
  'رہیں': 'rahein',
  'رہوں': 'rahoon',
  'رہیگا': 'rahega',
  'کا': 'ka',
  'کی': 'ki',
  'کے': 'ke',
  'کو': 'ko',
  'سے': 'se',
  'نے': 'ne',
  'پر': 'par',
  'پہ': 'pe',
  'تک': 'tak',
  'تلک': 'talak',
  'بھی': 'bhi',
  'ہی': 'hi',
  'نہ': 'na',
  'نا': 'na',
  'نہیں': 'nahin',
  'نہی': 'nahi',
  'مت': 'mat',
  'اور': 'aur',
  'یا': 'ya',
  'پھر': 'phir',
  'اب': 'ab',
  'جب': 'jab',
  'تب': 'tab',
  'کب': 'kab',
  'کبھی': 'kabhi',
  'اگر': 'agar',
  'مگر': 'magar',
  'لیکن': 'lekin',
  'کیونکہ': 'kyunki',
  'کہ': 'ke',
  'جو': 'jo',
  'جسے': 'jise',
  'جس': 'jis',
  'جن': 'jin',
  'جہاں': 'jahan',
  'وہاں': 'wahan',
  'یہاں': 'yahan',
  'یہیں': 'yahin',
  'وہیں': 'wahin',
  'کہاں': 'kahan',
  'کہیں': 'kahin',
  'کیوں': 'kyun',
  'کیا': 'kya',
  'کیسے': 'kaise',
  'کیسا': 'kaisa',
  'کیسی': 'kaisi',
  'کون': 'kaun',
  'کتنا': 'kitna',
  'کتنی': 'kitni',
  'کتنے': 'kitne',
  'اتنا': 'itna',
  'اتنی': 'itni',
  'اتنے': 'itne',
  'جتنا': 'jitna',
  'ایسا': 'aisa',
  'ایسی': 'aisi',
  'ایسے': 'aise',
  'ویسے': 'waise',
  'جیسے': 'jaise',
  'جیسا': 'jaisa',
  'بس': 'bas',
  'صرف': 'sirf',
  'بہت': 'bahut',
  'بڑا': 'bada',
  'بڑی': 'badi',
  'بڑے': 'bade',
  'چھوٹا': 'chhota',
  'چھوٹی': 'chhoti',
  'ذرا': 'zara',
  'ساتھ': 'saath',
  'پاس': 'paas',
  'دور': 'door',
  'آگے': 'aage',
  'پیچھے': 'peechhe',
  'اندر': 'andar',
  'باہر': 'bahar',
  'اوپر': 'upar',
  'نیچے': 'neeche',
  'بیچ': 'beech',
  'بنا': 'bina',
  'بن': 'bin',
  'بغیر': 'baghair',
  'لیے': 'liye',
  'لئے': 'liye',
  'واسطے': 'waaste',
  'خاطر': 'khaatir',
  'ایک': 'ek',
  'اک': 'ik',
  'دو': 'do',
  'دونوں': 'dono',
  'دونو': 'dono',
  'تین': 'teen',
  'چار': 'chaar',
  'پل': 'pal',
  'دن': 'din',
  'رات': 'raat',
  'راتیں': 'raatein',
  'شام': 'shaam',
  'صبح': 'subah',
  'سویرا': 'savera',
  'آج': 'aaj',
  'کل': 'kal',
  'آنکھ': 'aankh',
  'آنکھیں': 'aankhein',
  'آنکھوں': 'aankhon',
  'نظر': 'nazar',
  'نظریں': 'nazrein',
  'چہرہ': 'chehra',
  'ہاتھ': 'haath',
  'ہاتھوں': 'haathon',
  'دل': 'dil',
  'دلوں': 'dilon',
  'جاں': 'jaan',
  'جان': 'jaan',
  'جانِ': 'jaan-e',
  'روح': 'rooh',
  'سانس': 'saans',
  'سانسیں': 'saansein',
  'دھڑکن': 'dhadkan',
  'خون': 'khoon',
  'آنسو': 'aansu',
  'آنسوؤں': 'aansuon',
  'عشق': 'ishq',
  'محبت': 'mohabbat',
  'پیار': 'pyaar',
  'پریم': 'prem',
  'یار': 'yaar',
  'یارا': 'yaara',
  'دلبر': 'dilbar',
  'صنم': 'sanam',
  'ساجن': 'saajan',
  'سجنا': 'sajna',
  'ماہی': 'maahi',
  'ماہیا': 'maahiya',
  'جانم': 'jaanam',
  'جاناں': 'jaanan',
  'محبوب': 'mehboob',
  'عاشق': 'aashiq',
  'عاشقی': 'aashiqui',
  'دیوانہ': 'deewana',
  'دیوانی': 'deewani',
  'دیوانے': 'deewane',
  'پاگل': 'paagal',
  'وفا': 'wafa',
  'بےوفا': 'bewafa',
  'جفا': 'jafa',
  'یاد': 'yaad',
  'یادیں': 'yaadein',
  'یادوں': 'yaadon',
  'درد': 'dard',
  'غم': 'gham',
  'دکھ': 'dukh',
  'خوشی': 'khushi',
  'خوشیاں': 'khushiyan',
  'آرزو': 'aarzoo',
  'تمنا': 'tamanna',
  'خواب': 'khwaab',
  'خواہش': 'khwaahish',
  'سپنا': 'sapna',
  'سپنے': 'sapne',
  'ارمان': 'armaan',
  'وعدہ': 'waada',
  'وعدے': 'waade',
  'قسم': 'qasam',
  'بات': 'baat',
  'باتیں': 'baatein',
  'باتوں': 'baaton',
  'لفظ': 'lafz',
  'الفاظ': 'alfaaz',
  'حالت': 'haalat',
  'حال': 'haal',
  'فریاد': 'faryaad',
  'دعا': 'dua',
  'دعائیں': 'duaayein',
  'رب': 'rab',
  'خدا': 'khuda',
  'اللہ': 'Allah',
  'مولا': 'maula',
  'سجدہ': 'sajda',
  'عبادت': 'ibaadat',
  'نصیب': 'naseeb',
  'قسمت': 'qismat',
  'تقدیر': 'taqdeer',
  'زندگی': 'zindagi',
  'زندگانی': 'zindagaani',
  'موت': 'maut',
  'جینا': 'jeena',
  'جیتا': 'jeeta',
  'جیتے': 'jeete',
  'مرنا': 'marna',
  'مر': 'mar',
  'مرتا': 'marta',
  'مرتے': 'marte',
  'جدا': 'juda',
  'جدائی': 'judaai',
  'ملن': 'milan',
  'فاصلہ': 'faasla',
  'فاصلے': 'faasle',
  'تنہا': 'tanha',
  'تنہائی': 'tanhaai',
  'اکیلا': 'akela',
  'اکیلی': 'akeli',
  'انتظار': 'intezaar',
  'راہ': 'raah',
  'راہیں': 'raahein',
  'راہوں': 'raahon',
  'رستہ': 'rasta',
  'راستہ': 'raasta',
  'راستے': 'raaste',
  'منزل': 'manzil',
  'سفر': 'safar',
  'گھر': 'ghar',
  'شہر': 'shehar',
  'دنیا': 'duniya',
  'زمیں': 'zameen',
  'زمین': 'zameen',
  'آسماں': 'aasmaan',
  'آسمان': 'aasmaan',
  'چاند': 'chaand',
  'ستارے': 'sitaare',
  'سورج': 'sooraj',
  'بادل': 'baadal',
  'بارش': 'baarish',
  'ہوائیں': 'hawaayein',
  'پھول': 'phool',
  'خوشبو': 'khushboo',
  'موسم': 'mausam',
  'ساون': 'saawan',
  'بہار': 'bahaar',
  'دریا': 'dariya',
  'سمندر': 'samandar',
  'ساحل': 'saahil',
  'کنارہ': 'kinaara',
  'کنارے': 'kinaare',
  'آگ': 'aag',
  'پانی': 'paani',
  'روشنی': 'roshni',
  'اندھیرا': 'andhera',
  'سایہ': 'saaya',
  'رنگ': 'rang',
  'نور': 'noor',
  'حسن': 'husn',
  'حسین': 'haseen',
  'خوبصورت': 'khoobsurat',
  'ادا': 'ada',
  'ادائیں': 'adaayein',
  'وقت': 'waqt',
  'لمحہ': 'lamha',
  'لمحے': 'lamhe',
  'صدیاں': 'sadiyan',
  'عمر': 'umar',
  'سال': 'saal',
  'دوست': 'dost',
  'دوستی': 'dosti',
  'دشمن': 'dushman',
  'لوگ': 'log',
  'لوگوں': 'logon',
  'انساں': 'insaan',
  'انسان': 'insaan',
  'ماں': 'maa',
  'باپ': 'baap',
  'بیٹا': 'beta',
  'سچ': 'sach',
  'جھوٹ': 'jhooth',
  'سچا': 'sacha',
  'سچی': 'sachi',
  'دھوکہ': 'dhoka',
  'شکوہ': 'shikwa',
  'شکایت': 'shikaayat',
  'گلہ': 'gila',
  'گلے': 'gale',
  'سوال': 'sawaal',
  'جواب': 'jawaab',
  'مشکل': 'mushkil',
  'آسان': 'aasaan',
  'ضرورت': 'zaroorat',
  'عادت': 'aadat',
  'ڈر': 'dar',
  'خوف': 'khauf',
  'نشہ': 'nasha',
  'جام': 'jaam',
  'شراب': 'sharaab',
  'ساقی': 'saaqi',
  'محفل': 'mehfil',
  'دیوار': 'deewaar',
  'دروازہ': 'darwaaza',
  'کھڑکی': 'khidki',
  'تصویر': 'tasveer',
  'خط': 'khat',
  'نام': 'naam',
  'پتہ': 'pata',
  'خبر': 'khabar',
  'بےخبر': 'bekhabar',
  'چین': 'chain',
  'سکون': 'sukoon',
  'قرار': 'qaraar',
  'بےقرار': 'beqaraar',
  'جنون': 'junoon',
  'پاگلپن': 'paagalpan',
  'من': 'man',
  'تن': 'tan',
  'مان': 'maan',
  'ارے': 'arre',
  'اے': 'ae',
  'او': 'o',
  'ہائے': 'haaye',
  'ہاں': 'haan',
  'جی': 'ji',
  'شاید': 'shaayad',
  'ضرور': 'zaroor',
  'بالکل': 'bilkul',
  'کاش': 'kaash',
  'اچھا': 'achha',
  'اچھی': 'achhi',
  'اچھے': 'achhe',
  'برا': 'bura',
  'بری': 'buri',
  'برے': 'bure',
  'نیا': 'naya',
  'نئی': 'nayi',
  'نئے': 'naye',
  'پرانا': 'puraana',
  'پرانی': 'puraani',
  'پہلا': 'pehla',
  'پہلی': 'pehli',
  'پہلے': 'pehle',
  'آخری': 'aakhri',
  'آخر': 'aakhir',
  'ہر': 'har',
  'ہزار': 'hazaar',
  'لاکھ': 'laakh',
  'کئی': 'kai',
  'کم': 'kam',
  'زیادہ': 'zyaada',
  'بہتر': 'behtar',
  'پورا': 'poora',
  'پوری': 'poori',
  'آدھا': 'aadha',
  'خالی': 'khaali',
  'ادھورا': 'adhoora',
  'ادھوری': 'adhoori',
  'گہرا': 'gehra',
  'میٹھا': 'meetha',
  'کڑوا': 'kadwa',
  'ٹھنڈا': 'thanda',
  'بے': 'be',
  'آ': 'aa',
  'آؤ': 'aao',
  'آئے': 'aaye',
  'آئی': 'aayi',
  'آیا': 'aaya',
  'آتا': 'aata',
  'آتی': 'aati',
  'آتے': 'aate',
  'آنا': 'aana',
  'آکے': 'aake',
  'آکر': 'aakar',
  'آئیں': 'aayein',
  'آئیگا': 'aayega',
  'جا': 'ja',
  'جاؤ': 'jao',
  'جائے': 'jaaye',
  'جائیں': 'jaayein',
  'جاؤں': 'jaaun',
  'جانا': 'jaana',
  'جاتا': 'jaata',
  'جاتی': 'jaati',
  'جاتے': 'jaate',
  'گیا': 'gaya',
  'گئی': 'gayi',
  'گئے': 'gaye',
  'جاکے': 'jaake',
  'جائیگا': 'jaayega',
  'کر': 'kar',
  'کرو': 'karo',
  'کرے': 'kare',
  'کریں': 'karein',
  'کروں': 'karoon',
  'کرنا': 'karna',
  'کرتا': 'karta',
  'کرتی': 'karti',
  'کرتے': 'karte',
  'کئے': 'kiye',
  'کیے': 'kiye',
  'کرکے': 'karke',
  'دے': 'de',
  'دیا': 'diya',
  'دی': 'di',
  'دیے': 'diye',
  'دئیے': 'diye',
  'دینا': 'dena',
  'دیتا': 'deta',
  'دیتی': 'deti',
  'دیتے': 'dete',
  'دوں': 'doon',
  'لے': 'le',
  'لو': 'lo',
  'لیا': 'liya',
  'لی': 'li',
  'لینا': 'lena',
  'لیتا': 'leta',
  'لیتی': 'leti',
  'لوں': 'loon',
  'دیکھ': 'dekh',
  'دیکھو': 'dekho',
  'دیکھا': 'dekha',
  'دیکھی': 'dekhi',
  'دیکھے': 'dekhe',
  'دیکھوں': 'dekhun',
  'دیکھنا': 'dekhna',
  'دیکھتا': 'dekhta',
  'دیکھتی': 'dekhti',
  'دیکھتے': 'dekhte',
  'سن': 'sun',
  'سنو': 'suno',
  'سنا': 'suna',
  'سنی': 'suni',
  'سنے': 'sune',
  'سنتا': 'sunta',
  'بول': 'bol',
  'بولو': 'bolo',
  'بولا': 'bola',
  'بولی': 'boli',
  'بولے': 'bole',
  'کہہ': 'keh',
  'کہو': 'kaho',
  'کہا': 'kaha',
  'کہی': 'kahi',
  'کہے': 'kahe',
  'کہوں': 'kahoon',
  'کہنا': 'kehna',
  'کہنے': 'kehne',
  'کہتا': 'kehta',
  'کہتی': 'kehti',
  'کہتے': 'kehte',
  'چل': 'chal',
  'چلو': 'chalo',
  'چلا': 'chala',
  'چلی': 'chali',
  'چلے': 'chale',
  'چلنا': 'chalna',
  'رک': 'ruk',
  'رکو': 'ruko',
  'رکا': 'ruka',
  'مل': 'mil',
  'ملو': 'milo',
  'ملا': 'mila',
  'ملی': 'mili',
  'ملے': 'mile',
  'ملنا': 'milna',
  'ملنے': 'milne',
  'ملتا': 'milta',
  'ملتی': 'milti',
  'ملتے': 'milte',
  'پا': 'pa',
  'پاؤ': 'paao',
  'پایا': 'paaya',
  'پائے': 'paaye',
  'پاؤں': 'paaun',
  'پانا': 'paana',
  'سمجھ': 'samajh',
  'سمجھو': 'samjho',
  'سمجھا': 'samjha',
  'سمجھی': 'samjhi',
  'سمجھے': 'samjhe',
  'سمجھنا': 'samajhna',
  'جانو': 'jaano',
  'جانتا': 'jaanta',
  'جانتی': 'jaanti',
  'جانتے': 'jaante',
  'سوچ': 'soch',
  'سوچو': 'socho',
  'سوچا': 'socha',
  'سوچی': 'sochi',
  'سوچتا': 'sochta',
  'بھول': 'bhool',
  'بھولا': 'bhoola',
  'بھولی': 'bhooli',
  'بھولے': 'bhoole',
  'بھولنا': 'bhoolna',
  'روک': 'rok',
  'رو': 'ro',
  'رویا': 'roya',
  'روئے': 'roye',
  'رونا': 'rona',
  'روتا': 'rota',
  'روتی': 'roti',
  'ہنس': 'hans',
  'ہنسنا': 'hasna',
  'ہنستا': 'hansta',
  'گا': 'ga',
  'گی': 'gi',
  'گے': 'ge',
  'گاؤں': 'gaaun',
  'گانا': 'gaana',
  'سکا': 'saka',
  'سکی': 'saki',
  'سکے': 'sake',
  'سکتا': 'sakta',
  'سکتی': 'sakti',
  'سکتے': 'sakte',
  'چاہ': 'chaah',
  'چاہا': 'chaaha',
  'چاہیے': 'chahiye',
  'چاہتا': 'chahta',
  'چاہتی': 'chahti',
  'چاہتے': 'chahte',
  'چاہوں': 'chaahun',
  'بتا': 'bata',
  'بتاؤ': 'batao',
  'بتاؤں': 'bataoon',
  'بتایا': 'bataya',
  'بنی': 'bani',
  'بنے': 'bane',
  'بنتا': 'banta',
  'لگ': 'lag',
  'لگا': 'laga',
  'لگی': 'lagi',
  'لگے': 'lage',
  'لگتا': 'lagta',
  'لگتی': 'lagti',
  'ٹوٹ': 'toot',
  'ٹوٹا': 'toota',
  'ٹوٹی': 'tooti',
  'ٹوٹے': 'toote',
  'چھوڑ': 'chhod',
  'چھوڑا': 'chhoda',
  'چھوڑو': 'chhodo',
  'چھوڑے': 'chhode',
  'تھام': 'thaam',
  'رکھ': 'rakh',
  'رکھا': 'rakha',
  'رکھو': 'rakho',
  'بیت': 'beet',
  'بیتا': 'beeta',
  'بیتی': 'beeti',
  'گزر': 'guzar',
  'گزرا': 'guzra',
  'گزری': 'guzri',
  'جیو': 'jiyo',
  'جیوں': 'jiyun',
  'مانگ': 'maang',
  'مانگا': 'maanga',
  'ڈھونڈ': 'dhoond',
  'ڈھونڈا': 'dhoonda',
  'سنبھال': 'sambhaal',
  'اٹھ': 'uth',
  'اٹھا': 'utha',
  'بیٹھ': 'baith',
  'سو': 'so',
  'سوئے': 'soye',
  'جاگ': 'jaag',
  'جاگا': 'jaaga',
  'کھو': 'kho',
  'کھویا': 'khoya',
  'کھوئے': 'khoye',
  'کھونا': 'khona',
  'ہار': 'haar',
  'ہارا': 'haara',
  'جیت': 'jeet',
  'نبھا': 'nibha',
  'نبھانا': 'nibhaana',
  'سہ': 'seh',
  'سہا': 'saha',
  'سہنا': 'sehna',
  'تڑپ': 'tadap',
  'تڑپا': 'tadpa',
  'ترس': 'taras',
  'برس': 'baras',
  'برسا': 'barsa',
  'بہہ': 'beh',
  'بہا': 'baha',
  'جل': 'jal',
  'جلا': 'jala',
  'جلی': 'jali',
  'بجھ': 'bujh',
  'چھپ': 'chhup',
  'چھپا': 'chhupa',
  'چھو': 'chhoo',
  'چھوا': 'chhua',
  'ڈوب': 'doob',
  'ڈوبا': 'dooba',
  'اڑ': 'ud',
  'اڑا': 'uda',
  'گر': 'gir',
  'گرا': 'gira',
  'بدل': 'badal',
  'بدلا': 'badla',
  'بدلی': 'badli',
  'بدلے': 'badle',
  'نکل': 'nikal',
  'نکلا': 'nikla',
  'پہنچ': 'pahunch',
  'لوٹ': 'laut',
  'لوٹا': 'lauta',
  'مسکرا': 'muskura',
  'مسکراہٹ': 'muskurahat',
  'چمک': 'chamak',
  'سجا': 'saja',
};

/// [line] in Roman letters. Words that are not Urdu (English, numbers) stay.
String romanizeUrdu(String line, {bool capitalize = true}) {
  if (!hasArabicLetters(line)) return line;
  final r = romanizeUrduWords(urduWordsOf(line)).join().replaceAll(RegExp(r' {2,}'), ' ');
  return capitalize ? capitalizeFirst(r) : r;
}

/// The words of an Urdu line, each with the spaces after it (like splitWords).
List<String> urduWordsOf(String line) => [for (final m in RegExp(r'\S+\s*').allMatches(line)) m.group(0)!];

/// First letter of the line in capitals, like typed lyrics.
String capitalizeFirst(String r) {
  final i = r.indexOf(RegExp(r'[a-z]'));
  if (i < 0 || r.substring(0, i).contains(RegExp(r'[A-Za-z]'))) return r;
  return r.substring(0, i) + r[i].toUpperCase() + r.substring(i + 1);
}

/// The words of one line in Roman letters, one per word, reading the few
/// words that sound different by place: میں "main" (I) / "mein" (in),
/// تو "tu" (you) / "to" (then), بن "bin" (without) / "ban" (become).
List<String> romanizeUrduWords(List<String> words) {
  final out = [for (final w in words) romanizeUrduWord(w)];
  String core(int i) => i < 0 || i >= words.length ? '' : normalizeUrdu(words[i].replaceAll(RegExp(r'[^\p{L}]', unicode: true), ''));
  bool pause(int i) => i < 0 || RegExp(r'[،,؟?!.۔(]').hasMatch(words[i]);
  for (var i = 0; i < words.length; i++) {
    final c = core(i);
    String? say;
    if (c == 'میں') {
      final next = core(i + 1);
      final iWord = i == 0 || pause(i - 1) || const {'اور', 'کہ', 'جو', 'اب', 'پھر', 'جب', 'تو', 'بس', 'ہاں', 'نہ'}.contains(core(i - 1)) || _afterMain.contains(next);
      say = iWord ? 'main' : 'mein';
    } else if (c == 'تو') {
      say = i == 0 || pause(i - 1) || const {'جو', 'اب', 'کہ', 'اور', 'کیوں', 'جب', 'کیا', 'بس'}.contains(core(i - 1)) ? 'tu' : 'to';
    } else if (c == 'بن') {
      say = const {'کے', 'کر', 'گیا', 'گئی', 'گئے', 'جا', 'جاؤں', 'جائے', 'جاؤ', 'کہ'}.contains(core(i + 1)) ? 'ban' : 'bin';
    }
    if (say != null) out[i] = out[i].replaceFirst(urduWords[c]!, say);
  }
  return out;
}

/// Words that follow میں when it means "I" ("main teri", "main bhi").
const _afterMain = {'تیری', 'تیرا', 'تیرے', 'تجھے', 'تمہیں', 'تمھیں', 'تم', 'تو', 'نے', 'بھی', 'ہی', 'ہوں', 'تھا', 'تھی', 'کیا', 'کبھی', 'نہیں', 'نہ', 'اب', 'تجھ', 'کیسے', 'کہاں', 'یہ', 'وہ', 'جو', 'کچھ', 'خود', 'اپنا', 'اپنی', 'اپنے', 'ہر', 'آج', 'سوچوں', 'دیکھوں', 'کہوں', 'جاؤں', 'آؤں', 'رہوں', 'جیوں', 'مروں', 'چاہوں', 'کروں', 'ڈھونڈوں', 'پیار', 'یہاں', 'وہاں', 'تنہا', 'اکیلا'};

/// One Urdu word (with its punctuation and trailing space) in Roman letters.
String romanizeUrduWord(String word) {
  final m = RegExp(r'^(\s*)(.*?)(\s*)$', dotAll: true).firstMatch(word)!;
  final core = m.group(2)!;
  // split off punctuation around the letters: "(جو" , "مجھے،"
  final lead = RegExp(r'^[^\p{L}\p{M}\p{N}]*', unicode: true).firstMatch(core)!.group(0)!;
  final rest = core.substring(lead.length);
  final trail = RegExp(r'[^\p{L}\p{M}\p{N}]*$', unicode: true).firstMatch(rest)!.group(0)!;
  final body = rest.substring(0, rest.length - trail.length);
  return '${m.group(1)}${_punct(lead)}${_romanCore(body)}${_punct(trail)}${m.group(3)}';
}

String _romanCore(String w) {
  if (!hasArabicLetters(w)) return w;
  final n = normalizeUrdu(w);
  final known = urduWords[n];
  if (known != null) return known;
  // joined words: "تمھارے‌لیے", "دلکو" (a known word plus a short ending)
  for (final suffix in const ['کو', 'سے', 'نے', 'کا', 'کی', 'کے', 'میں']) {
    if (n.length > suffix.length + 1 && n.endsWith(suffix)) {
      final head = urduWords[n.substring(0, n.length - suffix.length)];
      if (head != null) return head + urduWords[suffix]!;
    }
  }
  // izafat: "جانِ" / "دلِ" (the mark was dropped) — plain reading below.
  return readUrduLetters(n);
}

const _cons = <String, String>{
  'ب': 'b', 'پ': 'p', 'ت': 't', 'ٹ': 't', 'ث': 's', 'ج': 'j', 'چ': 'ch', 'ح': 'h', 'خ': 'kh', 'د': 'd', 'ڈ': 'd', 'ذ': 'z', //
  'ر': 'r', 'ڑ': 'r', 'ز': 'z', 'ژ': 'zh', 'س': 's', 'ش': 'sh', 'ص': 's', 'ض': 'z', 'ط': 't', 'ظ': 'z', 'غ': 'gh', 'ف': 'f', //
  'ق': 'q', 'ک': 'k', 'گ': 'g', 'ل': 'l', 'م': 'm', 'ن': 'n', 'ں': 'n', 'ڻ': 'n', 'ڳ': 'g', 'ڄ': 'j',
};

/// Letter-by-letter reading of a word nobody listed: long vowels from the
/// letters (ا aa, و o/u, ی i/ee, ے e), the unwritten short "a" put between
/// consonants the way Hindi says them ("سب" sab, "درد" dard).
String readUrduLetters(String w) {
  final rs = w.runes.map(String.fromCharCode).toList();
  // tokens: ('c', latin) consonant, ('v', latin) vowel
  final t = <(bool, String)>[];
  for (var i = 0; i < rs.length; i++) {
    final c = rs[i];
    final first = t.isEmpty;
    final last = i == rs.length - 1;
    final prevCons = t.isNotEmpty && t.last.$1;
    switch (c) {
      case 'آ':
        t.add((false, 'aa'));
      case 'ا':
        t.add((false, first ? 'a' : 'aa'));
      case 'ع':
        if (first) t.add((false, 'a'));
      case 'و':
        if (first) {
          t.add((true, 'w'));
        } else if (!prevCons && t.isNotEmpty && t.last.$2 == 'a' && t.length == 1) {
          t.last = (false, 'au'); // اور aur
        } else {
          t.add((false, last ? 'o' : (i + 1 < rs.length && rs[i + 1] == 'ں' ? 'on' : 'o')));
          if (i + 1 < rs.length && rs[i + 1] == 'ں') i++;
        }
      case 'ؤ':
        t.add((false, 'o'));
      case 'ی':
        if (first) {
          t.add((true, 'y'));
        } else if (!prevCons && !last) {
          t.add((true, 'y'));
        } else {
          t.add((false, last ? 'i' : 'ee'));
        }
      case 'ئ':
        t.add((true, 'y'));
      case 'ے':
        t.add((false, prevCons || t.isEmpty ? 'e' : 'ye'));
      case 'ۓ':
        t.add((false, 'ye'));
      case 'ہ':
      case 'ۂ':
        if (last && prevCons) {
          t.add((false, 'a'));
        } else {
          t.add((true, 'h'));
        }
      case 'ھ':
        if (t.isNotEmpty && t.last.$1) {
          t.last = (true, '${t.last.$2}h');
        } else {
          t.add((true, 'h'));
        }
      case 'ء':
        break;
      default:
        final l = _cons[c];
        if (l != null) {
          t.add((true, l));
        } else {
          t.add((false, c));
        }
    }
  }
  // fill the short "a": a consonant followed by another consonant gets one
  // when it starts the word or comes after a vowel and is not the last of a
  // run of two before a vowel ("pyaar", "dard", "sab").
  final out = StringBuffer();
  for (var i = 0; i < t.length; i++) {
    final (isC, l) = t[i];
    out.write(l);
    if (!isC) continue;
    final nextC = i + 1 < t.length && t[i + 1].$1;
    if (!nextC) continue;
    final next = t[i + 1].$2;
    if (next == 'h' || next == 'y' && i == 0 || next == 'w' && i == 0) continue; // "kyun", "dhoop"
    final afterNext = i + 2 < t.length ? t[i + 2] : null;
    final prevV = i == 0 || !t[i - 1].$1;
    // C C V: the first C closes a syllable only after a vowel ("milna"), not at the start ("pyaar")
    if (afterNext != null && !afterNext.$1) {
      if (i == 0) out.write('a');
      continue;
    }
    if (prevV) out.write('a'); // "dard", "sab"
  }
  return out.toString();
}
