//
//  SEBTeacherPanelController.h
//  Safe Exam Browser — Teacher Panel
//
//  Окно, которое показывается при запуске SEB до начала контрольной:
//  «Начать контрольную», «Настройки преподавателя…» (по паролю), «Выйти».
//

#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

@interface SEBTeacherPanelController : NSWindowController <NSWindowDelegate>

+ (instancetype)sharedController;

/// Показать панель. completion(YES) — начать контрольную, completion(NO) — выйти из SEB.
- (void)showWithCompletion:(void (^)(BOOL startExam))completion;

@end

NS_ASSUME_NONNULL_END
