//
//  SEBTeacherSettings.m
//  Safe Exam Browser — Teacher Panel
//

#import "SEBTeacherSettings.h"
#import <Cocoa/Cocoa.h>
#import <CommonCrypto/CommonDigest.h>
#import <CommonCrypto/CommonHMAC.h>
#import <objc/runtime.h>
#import "NSUserDefaults+SEBEncryptedUserDefaults.h"
#import "Constants.h"

NSString * const SEBTeacherColorChangeDetectedNotification = @"SEBTeacherColorChangeDetectedNotification";

// SHA-256 пароля преподавателя (32123212). Чтобы сменить пароль, посчитайте
//   printf %s 'НОВЫЙ_ПАРОЛЬ' | shasum -a 256
// и замените строку ниже (строчными буквами).
static NSString * const SEBTeacherPasswordHash = @"cc889720062d23085370e56d1c66b16cdddd0be0e80f67377f18d06b43479767";

static NSString * const SEBTeacherSettingsVersionKey = @"version";
static NSString * const SEBTeacherSettingsValuesKey  = @"values";
static NSString * const SEBTeacherSettingsMACKey     = @"mac";

static NSString * const kStartURL                = @"startURL";
static NSString * const kQuitPasswordMode        = @"quitPasswordMode";
static NSString * const kHashedCustomQuitPW      = @"hashedCustomQuitPassword";
static NSString * const kRequirePasswordToStart  = @"requirePasswordToStart";

static NSString * const SEBPrefix = @"org_safeexambrowser_SEB_";


#pragma mark - SEBTeacherOption

@interface SEBTeacherOption ()
@property (nonatomic, copy, readwrite) NSString *optionID;
@property (nonatomic, copy, readwrite) NSString *title;
@property (nonatomic, copy, readwrite) NSString *hint;
@property (nonatomic, readwrite) NSInteger section;
@property (nonatomic, readwrite) BOOL valueFree;
@property (nonatomic, readwrite) BOOL valueStandard;
@property (nonatomic, readwrite) BOOL valueStrict;
@end

@implementation SEBTeacherOption

+ (instancetype)optionWithID:(NSString *)optionID
                     section:(NSInteger)section
                       title:(NSString *)title
                        hint:(NSString *)hint
                        free:(BOOL)free
                    standard:(BOOL)standard
                      strict:(BOOL)strict
{
    SEBTeacherOption *option = [SEBTeacherOption new];
    option.optionID = optionID;
    option.section = section;
    option.title = title;
    option.hint = hint;
    option.valueFree = free;
    option.valueStandard = standard;
    option.valueStrict = strict;
    return option;
}

- (BOOL)valueForPreset:(SEBTeacherPreset)preset
{
    switch (preset) {
        case SEBTeacherPresetFree:      return self.valueFree;
        case SEBTeacherPresetStrict:    return self.valueStrict;
        default:                        return self.valueStandard;
    }
}

@end


#pragma mark - Runtime hooks (⌘M / ⌘H)

static BOOL SEBTeacherShouldBlockMinimize(void)
{
    return [SEBTeacherSettings sharedSettings].blockMinimize;
}

@implementation NSWindow (SEBTeacherPanel)

- (void)sebteacher_miniaturize:(id)sender
{
    if (SEBTeacherShouldBlockMinimize()) {
        NSBeep();
        return;
    }
    [self sebteacher_miniaturize:sender]; // original implementation (swizzled)
}

- (void)sebteacher_performMiniaturize:(id)sender
{
    if (SEBTeacherShouldBlockMinimize()) {
        NSBeep();
        return;
    }
    [self sebteacher_performMiniaturize:sender]; // original implementation (swizzled)
}

@end

@implementation NSApplication (SEBTeacherPanel)

- (void)sebteacher_hide:(id)sender
{
    if (SEBTeacherShouldBlockMinimize()) {
        NSBeep();
        return;
    }
    [self sebteacher_hide:sender]; // original implementation (swizzled)
}

@end

static void SEBTeacherSwizzle(Class cls, SEL original, SEL replacement)
{
    Method origMethod = class_getInstanceMethod(cls, original);
    Method newMethod = class_getInstanceMethod(cls, replacement);
    if (!origMethod || !newMethod) {
        return;
    }
    if (class_addMethod(cls, original, method_getImplementation(newMethod), method_getTypeEncoding(newMethod))) {
        class_replaceMethod(cls, replacement, method_getImplementation(origMethod), method_getTypeEncoding(origMethod));
    } else {
        method_exchangeImplementations(origMethod, newMethod);
    }
}


#pragma mark - SEBTeacherSettings

@interface SEBTeacherSettings ()
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSNumber *> *optionValues;
@property (nonatomic, copy) NSDictionary *colorBaseline;
@property (nonatomic, strong, nullable) NSTimer *colorTimer;
@property (nonatomic) BOOL colorGuardRunning;
@end

@implementation SEBTeacherSettings

+ (instancetype)sharedSettings
{
    static SEBTeacherSettings *shared = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        shared = [[SEBTeacherSettings alloc] init];
        [shared reload];
    });
    return shared;
}

- (instancetype)init
{
    self = [super init];
    if (self) {
        _optionValues = [NSMutableDictionary new];
        _startURL = @"";
        _hashedCustomQuitPassword = @"";
        _quitPasswordMode = SEBTeacherQuitPasswordTeacher;
        _requirePasswordToStart = NO;
    }
    return self;
}


#pragma mark Описание переключателей

+ (NSArray<NSString *> *)sectionTitles
{
    return @[@"Экран и окна",
             @"Ограничения системы",
             @"Дополнения для студентов",
             @"Выход и служебное"];
}

+ (NSArray<SEBTeacherOption *> *)allOptions
{
    static NSArray *options = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        //                                                                   мягкий стандарт строгий
        options = @[
            // 0 — Экран и окна
            [SEBTeacherOption optionWithID:@"fullscreen" section:0
                                     title:@"Полноэкранный режим"
                                      hint:@"Окно контрольной занимает весь экран, без рамки и кнопок окна."
                                      free:NO standard:YES strict:YES],
            [SEBTeacherOption optionWithID:@"blockMinimize" section:0
                                     title:@"Запретить сворачивание и скрытие (⌘M, ⌘H)"
                                      hint:@"Окно SEB нельзя свернуть в Dock или скрыть."
                                      free:NO standard:YES strict:YES],
            [SEBTeacherOption optionWithID:@"singleDisplay" section:0
                                     title:@"Только один монитор"
                                      hint:@"Если подключён второй монитор, контрольная не начнётся."
                                      free:NO standard:YES strict:YES],
            [SEBTeacherOption optionWithID:@"blockMirroring" section:0
                                     title:@"Запретить дублирование экрана (AirPlay, проектор)"
                                      hint:@"Изображение нельзя вывести на другой экран или телевизор."
                                      free:NO standard:YES strict:YES],
            [SEBTeacherOption optionWithID:@"newWindows" section:0
                                     title:@"Разрешить ссылкам открывать новые окна"
                                      hint:@"Если выключено — ссылки открываются в том же окне, всплывающие окна блокируются."
                                      free:YES standard:YES strict:NO],
            [SEBTeacherOption optionWithID:@"showTaskBar" section:0
                                     title:@"Показывать нижнюю панель SEB"
                                      hint:@"Часы, заряд батареи, Wi-Fi и кнопки SEB внизу экрана."
                                      free:YES standard:YES strict:YES],

            // 1 — Ограничения системы
            [SEBTeacherOption optionWithID:@"blockAppSwitching" section:1
                                     title:@"Запретить другие программы"
                                      hint:@"Нельзя переключиться в другие приложения (⌘Tab, Dock, принудительное завершение)."
                                      free:NO standard:YES strict:YES],
            [SEBTeacherOption optionWithID:@"appSwitcherCheck" section:1
                                     title:@"Не запускать, если зажата клавиша ⌘"
                                      hint:@"Защита от обхода блокировки через переключатель программ при старте."
                                      free:NO standard:YES strict:YES],
            [SEBTeacherOption optionWithID:@"blockScreenCapture" section:1
                                     title:@"Запретить скриншоты и запись экрана"
                                      hint:@"Окно SEB не попадает на снимки и в запись экрана."
                                      free:NO standard:YES strict:YES],
            [SEBTeacherOption optionWithID:@"blockScreenSharing" section:1
                                     title:@"Запретить демонстрацию экрана и удалённый доступ"
                                      hint:@"Экран нельзя транслировать через «Общий экран», Zoom, Teams и т. п."
                                      free:YES standard:YES strict:YES],
            [SEBTeacherOption optionWithID:@"blockVM" section:1
                                     title:@"Запретить запуск в виртуальной машине"
                                      hint:@"SEB не запустится внутри Parallels, VMware, UTM и т. п."
                                      free:NO standard:YES strict:YES],
            [SEBTeacherOption optionWithID:@"privateClipboard" section:1
                                     title:@"Отдельный буфер обмена"
                                      hint:@"Нельзя вставить текст, скопированный до контрольной, и вынести текст из SEB."
                                      free:NO standard:YES strict:YES],
            [SEBTeacherOption optionWithID:@"detectAccessibilityApps" section:1
                                     title:@"Блокировать программы-помощники"
                                      hint:@"Приложения с правом «Универсальный доступ» (автокликеры, оверлеи) будут остановлены."
                                      free:NO standard:YES strict:YES],
            [SEBTeacherOption optionWithID:@"detectStoppedProcess" section:1
                                     title:@"Обнаруживать приостановку SEB"
                                      hint:@"Защита от «заморозки» SEB отладчиком или командой kill -STOP."
                                      free:NO standard:YES strict:YES],
            [SEBTeacherOption optionWithID:@"forceQuitWindowCheck" section:1
                                     title:@"Не запускать при открытом окне «Принудительное завершение»"
                                      hint:@"Если SEB ошибочно жалуется на это окно, хотя оно закрыто, выключите пункт. Принудительное завершение всё равно заблокировано во время контрольной."
                                      free:NO standard:NO strict:YES],
            [SEBTeacherOption optionWithID:@"colorGuard" section:1
                                     title:@"Запретить смену цветов экрана"
                                      hint:@"Инверсия, оттенки серого, цветофильтры, контраст, тёмная тема. При изменении экран блокируется до ввода пароля."
                                      free:NO standard:NO strict:YES],
            [SEBTeacherOption optionWithID:@"forceLightAppearance" section:1
                                     title:@"Всегда светлое оформление SEB"
                                      hint:@"Окна SEB не переключаются в тёмную тему вместе с системой."
                                      free:NO standard:YES strict:YES],

            // 2 — Дополнения для студентов
            [SEBTeacherOption optionWithID:@"spellCheck" section:2
                                     title:@"Проверка орфографии"
                                      hint:@"Подчёркивание ошибок в полях ввода."
                                      free:YES standard:NO strict:NO],
            [SEBTeacherOption optionWithID:@"dictionary" section:2
                                     title:@"Словарь"
                                      hint:@"Поиск значения слова (жест «Найти» / ⌃⌘D)."
                                      free:YES standard:NO strict:NO],
            [SEBTeacherOption optionWithID:@"dictation" section:2
                                     title:@"Диктовка"
                                      hint:@"Ввод текста голосом."
                                      free:YES standard:NO strict:NO],
            [SEBTeacherOption optionWithID:@"siri" section:2
                                     title:@"Siri"
                                      hint:@"Голосовой помощник."
                                      free:NO standard:NO strict:NO],
            [SEBTeacherOption optionWithID:@"print" section:2
                                     title:@"Печать"
                                      hint:@"Печать страницы контрольной."
                                      free:YES standard:NO strict:NO],
            [SEBTeacherOption optionWithID:@"find" section:2
                                     title:@"Поиск по странице (⌘F)"
                                      hint:@"Поиск текста на открытой странице."
                                      free:YES standard:YES strict:NO],
            [SEBTeacherOption optionWithID:@"zoom" section:2
                                     title:@"Масштабирование страницы"
                                      hint:@"Увеличение и уменьшение (⌘+ / ⌘−)."
                                      free:YES standard:YES strict:YES],
            [SEBTeacherOption optionWithID:@"downUploads" section:2
                                     title:@"Загрузка и скачивание файлов"
                                      hint:@"Прикрепление файлов к ответу и скачивание материалов."
                                      free:YES standard:YES strict:NO],
            [SEBTeacherOption optionWithID:@"rightMouse" section:2
                                     title:@"Правая кнопка мыши"
                                      hint:@"Контекстное меню на странице."
                                      free:YES standard:NO strict:NO],
            [SEBTeacherOption optionWithID:@"backForward" section:2
                                     title:@"Кнопки «Назад» и «Вперёд»"
                                      hint:@"Переход по истории страниц."
                                      free:YES standard:NO strict:NO],
            [SEBTeacherOption optionWithID:@"reload" section:2
                                     title:@"Перезагрузка страницы"
                                      hint:@"Кнопка и ⌘R."
                                      free:YES standard:YES strict:YES],
            [SEBTeacherOption optionWithID:@"showTime" section:2
                                     title:@"Часы на панели SEB"
                                      hint:@"Показывать текущее время."
                                      free:YES standard:YES strict:YES],
            [SEBTeacherOption optionWithID:@"devConsole" section:2
                                     title:@"Консоль разработчика"
                                      hint:@"Только для отладки, студентам не включать."
                                      free:NO standard:NO strict:NO],

            // 3 — Выход и служебное
            [SEBTeacherOption optionWithID:@"allowQuit" section:3
                                     title:@"Разрешить выход из SEB"
                                      hint:@"⌘Q и кнопка выхода. Пароль выхода задаётся ниже."
                                      free:YES standard:YES strict:YES],
            [SEBTeacherOption optionWithID:@"allowNativePreferences" section:3
                                     title:@"Встроенные настройки SEB по клавише Option"
                                      hint:@"Option при запуске открывает полное окно настроек SEB. Студентам не включать."
                                      free:NO standard:NO strict:NO],
        ];
    });
    return options;
}

+ (NSString *)titleForPreset:(SEBTeacherPreset)preset
{
    switch (preset) {
        case SEBTeacherPresetFree:      return @"Мягкий";
        case SEBTeacherPresetStandard:  return @"Стандартный";
        case SEBTeacherPresetStrict:    return @"Строгий";
        default:                        return @"Свой";
    }
}


#pragma mark Пароль

+ (NSString *)sha256HexString:(NSString *)string
{
    NSData *data = [[string precomposedStringWithCanonicalMapping] dataUsingEncoding:NSUTF8StringEncoding];
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(data.bytes, (CC_LONG)data.length, digest);
    NSMutableString *hex = [NSMutableString stringWithCapacity:CC_SHA256_DIGEST_LENGTH * 2];
    for (int i = 0; i < CC_SHA256_DIGEST_LENGTH; i++) {
        [hex appendFormat:@"%02x", digest[i]];
    }
    return hex.copy;
}

- (BOOL)checkTeacherPassword:(NSString *)password
{
    if (password.length == 0) {
        return NO;
    }
    return [[SEBTeacherSettings sha256HexString:password] isEqualToString:SEBTeacherPasswordHash];
}


#pragma mark Значения

- (BOOL)boolForOption:(NSString *)optionID
{
    NSNumber *value = self.optionValues[optionID];
    if (value) {
        return value.boolValue;
    }
    for (SEBTeacherOption *option in [SEBTeacherSettings allOptions]) {
        if ([option.optionID isEqualToString:optionID]) {
            return option.valueStandard;
        }
    }
    return NO;
}

- (void)setBool:(BOOL)value forOption:(NSString *)optionID
{
    self.optionValues[optionID] = @(value);
}

- (void)applyPreset:(SEBTeacherPreset)preset
{
    if (preset == SEBTeacherPresetCustom) {
        return;
    }
    for (SEBTeacherOption *option in [SEBTeacherSettings allOptions]) {
        self.optionValues[option.optionID] = @([option valueForPreset:preset]);
    }
}

- (SEBTeacherPreset)matchingPreset
{
    for (SEBTeacherPreset preset = SEBTeacherPresetFree; preset <= SEBTeacherPresetStrict; preset++) {
        BOOL matches = YES;
        for (SEBTeacherOption *option in [SEBTeacherSettings allOptions]) {
            if ([self boolForOption:option.optionID] != [option valueForPreset:preset]) {
                matches = NO;
                break;
            }
        }
        if (matches) {
            return preset;
        }
    }
    return SEBTeacherPresetCustom;
}

- (void)resetToDefaults
{
    [self.optionValues removeAllObjects];
    [self applyPreset:SEBTeacherPresetStandard];
    self.startURL = @"";
    self.quitPasswordMode = SEBTeacherQuitPasswordTeacher;
    self.hashedCustomQuitPassword = @"";
    self.requirePasswordToStart = NO;
}

- (BOOL)blockMinimize           { return [self boolForOption:@"blockMinimize"]; }
- (BOOL)colorGuardEnabled       { return [self boolForOption:@"colorGuard"]; }
- (BOOL)forceLightAppearance    { return [self boolForOption:@"forceLightAppearance"]; }
- (BOOL)allowNativePreferences  { return [self boolForOption:@"allowNativePreferences"]; }
- (BOOL)forceQuitWindowCheck    { return [self boolForOption:@"forceQuitWindowCheck"]; }


#pragma mark Хранение

- (NSURL *)settingsFileURL
{
    NSURL *appSupport = [[NSFileManager defaultManager] URLsForDirectory:NSApplicationSupportDirectory
                                                               inDomains:NSUserDomainMask].firstObject;
    NSURL *directory = [appSupport URLByAppendingPathComponent:@"SEB Teacher Panel" isDirectory:YES];
    return [directory URLByAppendingPathComponent:@"TeacherSettings.plist"];
}

- (NSDictionary *)valuesDictionary
{
    NSMutableDictionary *values = [NSMutableDictionary new];
    for (SEBTeacherOption *option in [SEBTeacherSettings allOptions]) {
        values[option.optionID] = @([self boolForOption:option.optionID]);
    }
    values[kStartURL] = self.startURL ?: @"";
    values[kQuitPasswordMode] = @(self.quitPasswordMode);
    values[kHashedCustomQuitPW] = self.hashedCustomQuitPassword ?: @"";
    values[kRequirePasswordToStart] = @(self.requirePasswordToStart);
    return values.copy;
}

// Каноническое текстовое представление для подписи (не зависит от порядка ключей).
- (NSString *)canonicalStringForValues:(NSDictionary *)values
{
    NSMutableString *canonical = [NSMutableString new];
    for (NSString *key in [values.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
        id value = values[key];
        NSString *valueString;
        if ([value isKindOfClass:[NSNumber class]]) {
            valueString = [NSString stringWithFormat:@"%lld", ((NSNumber *)value).longLongValue];
        } else if ([value isKindOfClass:[NSString class]]) {
            valueString = value;
        } else {
            valueString = @"?";
        }
        [canonical appendFormat:@"%@=%@\n", key, valueString];
    }
    return canonical.copy;
}

- (NSString *)macForValues:(NSDictionary *)values
{
    NSData *key = [[@"SEBTeacherPanel-v1:" stringByAppendingString:SEBTeacherPasswordHash] dataUsingEncoding:NSUTF8StringEncoding];
    NSData *data = [[self canonicalStringForValues:values] dataUsingEncoding:NSUTF8StringEncoding];
    unsigned char mac[CC_SHA256_DIGEST_LENGTH];
    CCHmac(kCCHmacAlgSHA256, key.bytes, key.length, data.bytes, data.length, mac);
    NSMutableString *hex = [NSMutableString stringWithCapacity:CC_SHA256_DIGEST_LENGTH * 2];
    for (int i = 0; i < CC_SHA256_DIGEST_LENGTH; i++) {
        [hex appendFormat:@"%02x", mac[i]];
    }
    return hex.copy;
}

- (BOOL)save
{
    NSDictionary *values = [self valuesDictionary];
    NSDictionary *file = @{SEBTeacherSettingsVersionKey : @1,
                           SEBTeacherSettingsValuesKey  : values,
                           SEBTeacherSettingsMACKey     : [self macForValues:values]};
    NSURL *url = [self settingsFileURL];
    NSError *error = nil;
    [[NSFileManager defaultManager] createDirectoryAtURL:url.URLByDeletingLastPathComponent
                             withIntermediateDirectories:YES
                                              attributes:nil
                                                   error:&error];
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:file
                                                              format:NSPropertyListBinaryFormat_v1_0
                                                             options:0
                                                               error:&error];
    if (!data) {
        NSLog(@"[TeacherPanel] Could not serialize settings: %@", error);
        return NO;
    }
    BOOL success = [data writeToURL:url options:NSDataWritingAtomic error:&error];
    if (!success) {
        NSLog(@"[TeacherPanel] Could not write settings to %@: %@", url.path, error);
    }
    return success;
}

- (void)reload
{
    [self resetToDefaults];

    NSData *data = [NSData dataWithContentsOfURL:[self settingsFileURL]];
    if (!data) {
        return; // первый запуск — «Стандартный»
    }
    NSDictionary *file = [NSPropertyListSerialization propertyListWithData:data options:0 format:NULL error:NULL];
    if (![file isKindOfClass:[NSDictionary class]]) {
        return;
    }
    NSDictionary *values = file[SEBTeacherSettingsValuesKey];
    NSString *mac = file[SEBTeacherSettingsMACKey];
    if (![values isKindOfClass:[NSDictionary class]] || ![mac isKindOfClass:[NSString class]] ||
        ![[self macForValues:values] isEqualToString:mac]) {
        NSLog(@"[TeacherPanel] Settings file signature mismatch — using defaults (Standard).");
        return;
    }

    for (SEBTeacherOption *option in [SEBTeacherSettings allOptions]) {
        NSNumber *value = values[option.optionID];
        if ([value isKindOfClass:[NSNumber class]]) {
            self.optionValues[option.optionID] = @(value.boolValue);
        }
    }
    if ([values[kStartURL] isKindOfClass:[NSString class]]) {
        self.startURL = values[kStartURL];
    }
    if ([values[kQuitPasswordMode] isKindOfClass:[NSNumber class]]) {
        NSInteger mode = [values[kQuitPasswordMode] integerValue];
        if (mode >= SEBTeacherQuitPasswordNone && mode <= SEBTeacherQuitPasswordCustom) {
            self.quitPasswordMode = mode;
        }
    }
    if ([values[kHashedCustomQuitPW] isKindOfClass:[NSString class]]) {
        self.hashedCustomQuitPassword = values[kHashedCustomQuitPW];
    }
    if ([values[kRequirePasswordToStart] isKindOfClass:[NSNumber class]]) {
        self.requirePasswordToStart = [values[kRequirePasswordToStart] boolValue];
    }
    if (self.quitPasswordMode == SEBTeacherQuitPasswordCustom && self.hashedCustomQuitPassword.length == 0) {
        self.quitPasswordMode = SEBTeacherQuitPasswordTeacher;
    }
}


#pragma mark Применение к настройкам SEB

- (void)applyToSEBPreferences
{
    NSUserDefaults *p = [NSUserDefaults standardUserDefaults];
    BOOL (^on)(NSString *) = ^BOOL(NSString *optionID) {
        return [self boolForOption:optionID];
    };
    void (^setBool)(NSString *, BOOL) = ^(NSString *key, BOOL value) {
        [p setSecureBool:value forKey:[SEBPrefix stringByAppendingString:key]];
    };
    void (^setInt)(NSString *, NSInteger) = ^(NSString *key, NSInteger value) {
        [p setSecureInteger:value forKey:[SEBPrefix stringByAppendingString:key]];
    };
    void (^setString)(NSString *, NSString *) = ^(NSString *key, NSString *value) {
        [p setSecureString:value forKey:[SEBPrefix stringByAppendingString:key]];
    };

    // Эта сборка подписывается без Apple-entitlement для Automatic Assessment
    // Configuration, поэтому всегда используется классический киоск-режим SEB.
    setInt(@"lockdownModePolicy", lockdownModePolicyEnforceClassic);

    // Экран и окна
    setInt(@"browserViewMode", on(@"fullscreen") ? browserViewModeFullscreen : browserViewModeWindow);
    setInt(@"allowedDisplaysMaxNumber", on(@"singleDisplay") ? 1 : 4);
    setBool(@"allowDisplayMirroring", !on(@"blockMirroring"));
    setInt(@"newBrowserWindowByLinkPolicy", on(@"newWindows") ? openInNewWindow : openInSameWindow);
    setBool(@"blockPopUpWindows", !on(@"newWindows"));
    setBool(@"showTaskBar", on(@"showTaskBar"));

    // Ограничения системы
    setBool(@"allowSwitchToApplications", !on(@"blockAppSwitching"));
    setBool(@"enableAppSwitcherCheck", on(@"appSwitcherCheck"));
    setBool(@"allowScreenCapture", !on(@"blockScreenCapture"));
    setBool(@"allowWindowCapture", !on(@"blockScreenCapture"));
    setBool(@"allowScreenSharing", !on(@"blockScreenSharing"));
    setBool(@"screenSharingMacEnforceBlocked", on(@"blockScreenSharing"));
    setBool(@"allowVirtualMachine", !on(@"blockVM"));
    setBool(@"enablePrivateClipboard", on(@"privateClipboard"));
    setBool(@"detectAccessibilityApps", on(@"detectAccessibilityApps"));
    setBool(@"detectStoppedProcess", on(@"detectStoppedProcess"));

    // Дополнения
    setBool(@"allowSpellCheck", on(@"spellCheck"));
    setBool(@"allowDictionaryLookup", on(@"dictionary"));
    setBool(@"allowDictation", on(@"dictation"));
    setBool(@"allowSiri", on(@"siri"));
    setBool(@"allowPrint", on(@"print"));
    setBool(@"allowFind", on(@"find"));
    setBool(@"enableZoomPage", on(@"zoom"));
    setBool(@"allowDownUploads", on(@"downUploads"));
    setBool(@"allowDownloads", on(@"downUploads"));
    setBool(@"enableRightMouseMac", on(@"rightMouse"));
    setBool(@"allowBrowsingBackForward", on(@"backForward"));
    setBool(@"newBrowserWindowNavigation", on(@"backForward"));
    setBool(@"browserWindowAllowReload", on(@"reload"));
    setBool(@"newBrowserWindowAllowReload", on(@"reload"));
    setBool(@"showReloadButton", on(@"reload"));
    setBool(@"showTime", on(@"showTime"));
    setBool(@"allowDeveloperConsole", on(@"devConsole"));

    // Выход
    setBool(@"allowQuit", on(@"allowQuit"));
    setBool(@"showQuitButton", on(@"allowQuit"));
    setBool(@"allowPreferencesWindow", on(@"allowNativePreferences"));
    switch (self.quitPasswordMode) {
        case SEBTeacherQuitPasswordTeacher:
            setString(@"hashedQuitPassword", SEBTeacherPasswordHash);
            break;
        case SEBTeacherQuitPasswordCustom:
            setString(@"hashedQuitPassword", self.hashedCustomQuitPassword.length > 0 ? self.hashedCustomQuitPassword : SEBTeacherPasswordHash);
            break;
        default:
            setString(@"hashedQuitPassword", @"");
            break;
    }

    // Адрес контрольной
    NSString *url = [self.startURL stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (url.length > 0) {
        setString(@"startURL", url);
    }

    // Оформление
    if (@available(macOS 10.14, *)) {
        NSApp.appearance = self.forceLightAppearance ? [NSAppearance appearanceNamed:NSAppearanceNameAqua] : nil;
    }

    NSLog(@"[TeacherPanel] Applied teacher settings (preset: %@)", [SEBTeacherSettings titleForPreset:[self matchingPreset]]);
}


#pragma mark Перехват ⌘M / ⌘H

- (void)installRuntimeHooks
{
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        SEBTeacherSwizzle([NSWindow class], @selector(miniaturize:), @selector(sebteacher_miniaturize:));
        SEBTeacherSwizzle([NSWindow class], @selector(performMiniaturize:), @selector(sebteacher_performMiniaturize:));
        SEBTeacherSwizzle([NSApplication class], @selector(hide:), @selector(sebteacher_hide:));
    });
}


#pragma mark Контроль цветов экрана

static id SEBTeacherCopyPref(CFStringRef key, CFStringRef domain)
{
    CFPreferencesAppSynchronize(domain);
    CFPropertyListRef value = CFPreferencesCopyAppValue(key, domain);
    if (!value) {
        return [NSNull null];
    }
    return CFBridgingRelease(value);
}

- (NSDictionary *)currentColorState
{
    NSWorkspace *workspace = [NSWorkspace sharedWorkspace];
    NSMutableDictionary *state = [NSMutableDictionary new];
    state[@"Инверсия цветов"] = @(workspace.accessibilityDisplayShouldInvertColors);
    state[@"Увеличение контраста"] = @(workspace.accessibilityDisplayShouldIncreaseContrast);
    state[@"Различение без цвета"] = @(workspace.accessibilityDisplayShouldDifferentiateWithoutColor);
    state[@"Уменьшение прозрачности"] = @(workspace.accessibilityDisplayShouldReduceTransparency);
    state[@"Цветофильтр"] = SEBTeacherCopyPref(CFSTR("__Color__-MADisplayFilterCategoryEnabled"), CFSTR("com.apple.mediaaccessibility"));
    state[@"Тип цветофильтра"] = SEBTeacherCopyPref(CFSTR("__Color__-MADisplayFilterType"), CFSTR("com.apple.mediaaccessibility"));
    state[@"Оттенки серого"] = SEBTeacherCopyPref(CFSTR("grayscale"), CFSTR("com.apple.universalaccess"));
    state[@"Тёмная тема"] = SEBTeacherCopyPref(CFSTR("AppleInterfaceStyle"), kCFPreferencesAnyApplication);
    return state.copy;
}

- (void)startColorGuard
{
    if (!self.colorGuardEnabled) {
        [self stopColorGuard];
        return;
    }
    self.colorBaseline = [self currentColorState];
    if (self.colorGuardRunning) {
        return;
    }
    self.colorGuardRunning = YES;

    [[[NSWorkspace sharedWorkspace] notificationCenter] addObserver:self
                                                           selector:@selector(colorStateMightHaveChanged:)
                                                               name:NSWorkspaceAccessibilityDisplayOptionsDidChangeNotification
                                                             object:nil];
    [[NSDistributedNotificationCenter defaultCenter] addObserver:self
                                                        selector:@selector(colorStateMightHaveChanged:)
                                                            name:@"AppleInterfaceThemeChangedNotification"
                                                          object:nil];
    // Цветофильтры и оттенки серого не присылают уведомлений — опрашиваем.
    self.colorTimer = [NSTimer timerWithTimeInterval:2.0
                                              target:self
                                            selector:@selector(colorStateMightHaveChanged:)
                                            userInfo:nil
                                             repeats:YES];
    [[NSRunLoop mainRunLoop] addTimer:self.colorTimer forMode:NSRunLoopCommonModes];
    NSLog(@"[TeacherPanel] Color guard started");
}

- (void)stopColorGuard
{
    if (!self.colorGuardRunning) {
        return;
    }
    self.colorGuardRunning = NO;
    [self.colorTimer invalidate];
    self.colorTimer = nil;
    [[[NSWorkspace sharedWorkspace] notificationCenter] removeObserver:self
                                                                  name:NSWorkspaceAccessibilityDisplayOptionsDidChangeNotification
                                                                object:nil];
    [[NSDistributedNotificationCenter defaultCenter] removeObserver:self
                                                               name:@"AppleInterfaceThemeChangedNotification"
                                                             object:nil];
}

- (void)rebaseColorGuard
{
    if (self.colorGuardRunning) {
        self.colorBaseline = [self currentColorState];
    }
}

- (void)colorStateMightHaveChanged:(id)sender
{
    if (!self.colorGuardRunning) {
        return;
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        NSDictionary *current = [self currentColorState];
        NSMutableArray *changed = [NSMutableArray new];
        for (NSString *key in current) {
            id before = self.colorBaseline[key];
            id now = current[key];
            if (before && ![before isEqual:now]) {
                [changed addObject:key];
            }
        }
        if (changed.count == 0) {
            return;
        }
        [changed sortUsingSelector:@selector(compare:)];
        NSString *reason = [changed componentsJoinedByString:@", "];
        NSLog(@"[TeacherPanel] Screen colors changed during exam: %@", reason);
        // Новое состояние принимаем как базовое, чтобы не блокировать повторно
        // одно и то же изменение; следующее изменение снова вызовет блокировку.
        self.colorBaseline = current;
        [[NSNotificationCenter defaultCenter] postNotificationName:SEBTeacherColorChangeDetectedNotification
                                                            object:self
                                                          userInfo:@{@"reason" : reason}];
    });
}

@end
