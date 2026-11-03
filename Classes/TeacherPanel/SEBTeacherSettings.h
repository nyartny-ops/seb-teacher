//
//  SEBTeacherSettings.h
//  Safe Exam Browser — Teacher Panel
//
//  Настройки уровня контроля, которые преподаватель задаёт в панели перед
//  запуском контрольной. Хранятся отдельно от настроек SEB (в
//  ~/Library/Application Support/SEB Teacher Panel/TeacherSettings.plist,
//  защищены HMAC от ручной правки) и при каждом старте сессии накладываются
//  поверх текущих настроек SEB (клиентских или из .seb файла).
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Отправляется, когда во время контрольной изменились цвета экрана
/// (инверсия, контраст, фильтры, оттенки серого, тёмная тема).
/// userInfo[@"reason"] — человекочитаемое описание изменения.
extern NSString * const SEBTeacherColorChangeDetectedNotification;

typedef NS_ENUM(NSInteger, SEBTeacherPreset) {
    SEBTeacherPresetFree        = 0,   // Мягкий
    SEBTeacherPresetStandard    = 1,   // Стандартный
    SEBTeacherPresetStrict      = 2,   // Строгий
    SEBTeacherPresetCustom      = 3    // Свой (не совпадает ни с одним)
};

typedef NS_ENUM(NSInteger, SEBTeacherQuitPasswordMode) {
    SEBTeacherQuitPasswordNone      = 0,   // Без пароля
    SEBTeacherQuitPasswordTeacher   = 1,   // Пароль преподавателя
    SEBTeacherQuitPasswordCustom    = 2    // Отдельный пароль
};

/// Описание одного переключателя в панели.
@interface SEBTeacherOption : NSObject
@property (nonatomic, copy, readonly) NSString *optionID;
@property (nonatomic, copy, readonly) NSString *title;
@property (nonatomic, copy, readonly) NSString *hint;
@property (nonatomic, readonly) NSInteger section;
/// Значение в пресетах: [Мягкий, Стандартный, Строгий]
@property (nonatomic, readonly) BOOL valueFree;
@property (nonatomic, readonly) BOOL valueStandard;
@property (nonatomic, readonly) BOOL valueStrict;
- (BOOL)valueForPreset:(SEBTeacherPreset)preset;
@end


@interface SEBTeacherSettings : NSObject

+ (instancetype)sharedSettings;

/// Заголовки разделов панели (индекс = SEBTeacherOption.section)
+ (NSArray<NSString *> *)sectionTitles;
+ (NSArray<SEBTeacherOption *> *)allOptions;
+ (NSString *)titleForPreset:(SEBTeacherPreset)preset;

#pragma mark Пароль преподавателя
- (BOOL)checkTeacherPassword:(NSString *)password;
+ (NSString *)sha256HexString:(NSString *)string;

#pragma mark Значения
- (BOOL)boolForOption:(NSString *)optionID;
- (void)setBool:(BOOL)value forOption:(NSString *)optionID;

/// Адрес контрольной. Пустая строка = оставить адрес из настроек SEB/.seb файла.
@property (nonatomic, copy) NSString *startURL;
@property (nonatomic) SEBTeacherQuitPasswordMode quitPasswordMode;
/// SHA-256 (hex) отдельного пароля выхода (для SEBTeacherQuitPasswordCustom)
@property (nonatomic, copy) NSString *hashedCustomQuitPassword;
/// Требовать пароль преподавателя и для кнопки «Начать контрольную»
@property (nonatomic) BOOL requirePasswordToStart;

- (void)applyPreset:(SEBTeacherPreset)preset;
- (SEBTeacherPreset)matchingPreset;
- (void)resetToDefaults;

/// Сохранить на диск (с подписью HMAC). Возвращает NO при ошибке записи.
- (BOOL)save;
/// Перечитать с диска (если файл изменён вручную — откат к «Стандартному»).
- (void)reload;

#pragma mark Применение
/// Записать выбранные ограничения в настройки SEB. Вызывается перед каждым
/// стартом/перезапуском сессии.
- (void)applyToSEBPreferences;

#pragma mark Собственные ограничения панели (вне штатных настроек SEB)
@property (nonatomic, readonly) BOOL blockMinimize;
@property (nonatomic, readonly) BOOL colorGuardEnabled;
@property (nonatomic, readonly) BOOL forceLightAppearance;
@property (nonatomic, readonly) BOOL allowNativePreferences;

/// Однократно устанавливает перехват ⌘M / ⌘H (сворачивание, скрытие).
- (void)installRuntimeHooks;
/// Запомнить текущее состояние цветов экрана и начать следить за изменениями.
- (void)startColorGuard;
- (void)stopColorGuard;
/// Принять текущие цвета экрана как допустимые (после разблокировки).
- (void)rebaseColorGuard;

@end

NS_ASSUME_NONNULL_END
