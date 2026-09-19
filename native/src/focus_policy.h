#ifndef LP32_FOCUS_POLICY_H
#define LP32_FOCUS_POLICY_H
/* Environment overrides the bundle setting; absence of both means off. */
int lp32_focus_setting(const char *environment, int bundle_default);
int lp32_continue_when_inactive(void);
int lp32_ignore_guest_focus_loss(void);
int lp32_suppress_background_input(void);
/* An inactive app is never focused even if AppKit retains a stale key flag.
   Windowed games also require their own window to be key; borderless fullscreen
   games tolerate AppKit's asynchronous key-window assignment. */
int lp32_guest_focus_from_app_state(int application_active, int window_key,
                                     int fullscreen);
#endif
