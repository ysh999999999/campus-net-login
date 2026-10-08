#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
校园网自动检测与登录脚本
使用 Playwright 控制 Edge 浏览器

================================================================================
关于本文件的来源（重要）
================================================================================
本项目原先只分发了打包后的 CampusNetLogin.exe，Python 源码已遗失，
一旦 Edge 大版本更新、校园网改版或验证码样式变化，将无法修复。

本文件是 2026-10-02 从 CampusNetLogin.exe 中还原出来的：
  1. 解析 exe 尾部的 PyInstaller CArchive cookie，定位 TOC
  2. 从 TOC 中取出主脚本条目 campus_net_login（typecode 's'，zlib 压缩的 marshal 数据）
  3. marshal 反序列化得到 code object，再用 dis 反汇编逐函数还原
因此本文件在**逻辑与行为**上与打包的 exe 等价，但注释、变量命名与部分代码组织
属于还原过程中的整理，可能与原始源码存在细节差异。

依赖栈（由 exe 的 PYZ 与解压目录确认）：
  Python 3.13 + playwright + ddddocr + onnxruntime + opencv + numpy + Pillow + psutil

用法：
  python campus_net_login.py                 # 交互菜单
  python campus_net_login.py --auto          # 自动模式（计划任务调用的就是这个）
  python campus_net_login.py --enable-autostart
  python campus_net_login.py --disable-autostart
"""

import json
import sys
import time
import os
import winreg
from playwright.sync_api import sync_playwright

AUTOSTART_REG_KEY = r'Software\Microsoft\Windows\CurrentVersion\Run'
AUTOSTART_REG_NAME = 'CampusNetLogin'


def step_log(step_num, total_steps, status, message, detail=''):
    """醒目的步骤提示，同时输出到控制台和日志文件。

    status: 'start' | 'ok' | 'fail' | 'info' | 'wait'
    """
    icons = {
        'start': '⏳',
        'ok': '✅',
        'fail': '❌',
        'info': 'ℹ️',
        'wait': '⏸️',
    }
    icon = icons.get(status, '  ')
    prefix = f'  [{step_num}/{total_steps}]'
    line = f'{prefix} {icon}  {message}'
    if detail:
        line += f'  →  {detail}'
    print(line)
    try:
        from datetime import datetime
        log_path = os.path.join(BASE_DIR, 'login_steps.log')
        with open(log_path, 'a', encoding='utf-8') as lf:
            ts = datetime.now().strftime('%Y-%m-%d %H:%M:%S')
            lf.write(f'{ts} {line}\n')
    except Exception:
        pass


def banner(text, char='='):
    """打印醒目的分隔横幅"""
    bar = char * 60
    print(f'\n{bar}')
    print(f'  {text}')
    print(bar)


def dev_banner():
    """开发者标志横幅：主题写死在源码内，仅作标识，不改变任何登录行为"""
    bar = '#' * 60
    print(f'\n{bar}')
    print(f'###  {DEV_SHOW}  ·  DEVELOPER MODE')
    print(f'###  {DEV_QUOTE}')
    print('###  仅作标识，登录行为与普通模式完全一致')
    print(bar)


def get_exe_path():
    """获取当前 exe 或脚本的完整路径"""
    if getattr(sys, 'frozen', False):
        return os.path.abspath(sys.executable)
    return os.path.abspath(__file__)


def is_autostart_enabled():
    """检查开机自启动是否已开启"""
    try:
        key = winreg.OpenKey(winreg.HKEY_CURRENT_USER, AUTOSTART_REG_KEY)
        value, _ = winreg.QueryValueEx(key, AUTOSTART_REG_NAME)
        winreg.CloseKey(key)
        return True, value
    except FileNotFoundError:
        return False, None
    except Exception:
        return False, None


def enable_autostart():
    """开启开机自启动（写入注册表）"""
    exe_path = get_exe_path()
    reg_value = f'"{exe_path}" --auto'
    try:
        key = winreg.OpenKey(winreg.HKEY_CURRENT_USER, AUTOSTART_REG_KEY,
                             0, winreg.KEY_SET_VALUE)
        winreg.SetValueEx(key, AUTOSTART_REG_NAME, 0, winreg.REG_SZ, reg_value)
        winreg.CloseKey(key)
        print('[自启动] 已开启开机自启动')
        print(f'[自启动] 注册路径: HKCU\\{AUTOSTART_REG_KEY}\\{AUTOSTART_REG_NAME}')
        print(f'[自启动] 启动命令: {reg_value}')
        return True
    except Exception as e:
        print(f'[自启动] 开启失败: {e}')
        return False


def disable_autostart():
    """关闭开机自启动（从注册表删除）"""
    try:
        key = winreg.OpenKey(winreg.HKEY_CURRENT_USER, AUTOSTART_REG_KEY,
                             0, winreg.KEY_SET_VALUE)
        winreg.DeleteValue(key, AUTOSTART_REG_NAME)
        winreg.CloseKey(key)
        print('[自启动] 已关闭开机自启动')
        return True
    except FileNotFoundError:
        print('[自启动] 自启动未开启，无需关闭')
        return True
    except Exception as e:
        print(f'[自启动] 关闭失败: {e}')
        return False


# ---------------------------------------------------------------------------
# 配置加载
# 打包后 sys.frozen 为真，BASE_DIR 取 exe 所在目录；源码运行时取脚本目录。
# 注意：exe 与 campus_net_config.json 必须位于同一目录，否则登录会失效。
# ---------------------------------------------------------------------------
if getattr(sys, 'frozen', False):
    BASE_DIR = os.path.dirname(sys.executable)
else:
    BASE_DIR = os.path.abspath(os.path.dirname(__file__))

config_path = os.path.join(BASE_DIR, 'campus_net_config.json')
if not os.path.exists(config_path):
    config_path = os.path.join(os.path.expanduser('~'), 'campus_net_config.json')

with open(config_path, 'r', encoding='utf-8') as f:
    config = json.load(f)

ACCOUNT = config['campus_network']['account']
PASSWORD = config['campus_network']['password']
LOGIN_URL = config['campus_network']['login_url']
TEST_URL = config.get('test_url', 'https://www.bilibili.com')
BILIBILI_URL = config.get('bilibili_url', 'https://www.bilibili.com')
MAX_RETRIES = config.get('max_retries', 3)
WAIT_AFTER_LOGIN = config.get('wait_after_login_seconds', 120)

# 开发者标志：以《甄嬛传》为主题，写死在源码内（不读配置、不提供修改入口）。
# 仅影响显示，不改变登录行为。
DEV_MODE = True
DEV_LABEL = '甄嬛传'
DEV_OWNER = '熹贵妃'
DEV_QUOTE = '「臣妾做不到啊」—— 除非开着开发者模式'
DEV_SHOW = DEV_LABEL + ' · ' + DEV_OWNER

AUTO_MODE = False
CHECK_INTERVAL_HOURS = 3
STATE_FILE = 'last_run_time.json'

# 通过访问这些地址触发校园网门户重定向，从而到达登录页
REDIRECT_URLS = (
    'http://1.1.1.1',
    'http://3.3.3.3',
    'http://www.baidu.com',
    'http://neverssl.com',
)

TOTAL_STEPS = 8

# 账号输入框候选选择器（按优先级尝试）
ACCOUNT_SELECTORS = (
    'input[name="username"]', 'input[name="account"]', 'input[name="user"]',
    'input[name="userid"]', 'input[name="loginname"]', 'input[name="user_name"]',
    'input[placeholder*="账号"]', 'input[placeholder*="用户"]',
    'input[placeholder*="学号"]', 'input[placeholder*="account"]',
    'input[placeholder*="user"]',
    '#username', '#account', '#user', '#userid',
)

# 密码输入框候选选择器
PASSWORD_SELECTORS = (
    'input[name="password"]', 'input[name="passwd"]', 'input[name="pwd"]',
    'input[placeholder*="密码"]', 'input[placeholder*="password"]',
    'input[placeholder*="登录密码"]', 'input[placeholder*="输入你的登录密码"]',
    '#password', '#passwd', '#pwd',
)

# 验证码图片候选选择器
CAPTCHA_IMG_SELECTORS = (
    'img[id*="captcha"]', 'img[id*="verify"]', 'img[id*="code"]',
    'img[src*="captcha"]', 'img[src*="verify"]', 'img[src*="code"]',
    'img[src*="rand"]',
    'img[class*="captcha"]', 'img[class*="verify"]', 'img[class*="code"]',
)

# 验证码输入框候选选择器
CAPTCHA_INPUT_SELECTORS = (
    'input[name="captcha"]', 'input[name="verify"]', 'input[name="code"]',
    'input[name="vcode"]', 'input[name="checkcode"]', 'input[name="randcode"]',
    'input[placeholder*="验证"]', 'input[placeholder*="captcha"]',
    'input[placeholder*="code"]',
    '#captcha', '#verify', '#code', '#vcode',
)

# 登录按钮候选选择器
LOGIN_BUTTON_SELECTORS = [
    'button[type="submit"]', 'input[type="submit"]', 'input[type="button"]',
    'button[class*="login"]', 'a[class*="login"]',
    'button:has-text("提交登入")', 'button:has-text("提交登录")',
    'button:has-text("提交")', 'button:has-text("登入")',
    'button:has-text("登录")', 'button:has-text("Login")',
    'button:has-text("确定")',
    'a:has-text("提交登入")', 'a:has-text("提交登录")',
    'a:has-text("登入")', 'a:has-text("登录")', 'a:has-text("Login")',
    'input[value="提交登入"]', 'input[value="提交登录"]',
    'input[value="登录"]', 'input[value="Login"]',
    '#login', '#submit', '#btn-login', '.login-btn', '.btn-login', '.submit',
]

# 兜底：按钮文案关键字
LOGIN_BUTTON_TEXTS = (
    '提交登入', '提交登录', '登入', '登录', 'login', '确定', 'submit',
)

# B站推荐视频候选选择器
VIDEO_SELECTORS = [
    'a.bili-video-card__info--owner', '.bili-video-card__info--title a',
    '.video-card__info-title a', '.bili-video-card a', '.video-list-item a',
    'a[href*="/video/"]',
]


def save_run_time():
    """记录当前运行时间到状态文件"""
    from datetime import datetime
    now = datetime.now()
    try:
        with open(STATE_FILE, 'w', encoding='utf-8') as f:
            json.dump({'last_run': now.strftime('%Y-%m-%d %H:%M:%S')},
                      f, ensure_ascii=False)
    except Exception as e:
        print(f'[调度] 保存运行时间失败: {e}')


def show_next_check_time():
    """显示监控调度信息"""
    from datetime import datetime  # noqa: F401  (保持与还原逻辑一致)
    print('=' * 60)
    print('  监控调度信息')
    print('  ────────────────────────────────────────────')
    print('  Ping 检测:  每 5 分钟（轻量级，不启动浏览器）')
    print('  完整检测:   每 1 小时（启动浏览器全面检查）')
    print('  断网响应:   ping 失败后立即启动登录')
    print('  ────────────────────────────────────────────')
    try:
        with open(STATE_FILE, 'r', encoding='utf-8') as f:
            data = json.load(f)
        last_run = data['last_run']
        print(f'  上次完整检测: {last_run}')
    except Exception:
        print('  上次完整检测: (无记录)')
    print('  详细步骤日志: login_steps.log')
    print('  监控运行日志: monitor.log')
    print('=' * 60)


def check_network(page):
    """检测网络是否正常：访问B站，检查是否正常加载"""
    try:
        page.goto(TEST_URL, timeout=20000, wait_until='commit')
        time.sleep(5)
        current_url = page.url
        title = page.title()

        # 被劫持到认证门户 => 断网
        if ('2.2.2.2' in current_url
                or 'login' in current_url.lower()
                or 'portal' in current_url.lower()):
            print(f'[网络检测] 页面跳转至登录页: {current_url}')
            return False

        # 正常到达 B 站 => 在线
        if ('bilibili' in current_url
                or '哔哩' in title
                or 'bilibili' in title.lower()):
            print(f'[网络检测] 网络正常! URL: {current_url}, Title: {title}')
            return True

        print(f'[网络检测] 无法确定网络状态. URL: {current_url}, Title: {title}')
        return False
    except Exception as e:
        err_str = str(e)
        if 'ERR_ABORTED' in err_str:
            # 访问被中断通常意味着被重定向到认证页
            print('[网络检测] 访问被中断（可能跳转至登录页）')
            try:
                current_url = page.url
                print(f'[网络检测] 当前URL: {current_url}')
                if ('2.2.2.2' in current_url
                        or 'login' in current_url.lower()
                        or 'portal' in current_url.lower()):
                    return False
            except Exception:
                pass
            return False
        print(f'[网络检测] 访问失败: {err_str[:200]}')
        return False


def try_reach_login_page(page, retry_num):
    """尝试多种方式到达校园网登录页面"""
    print(f'[登录] 尝试直接访问: {LOGIN_URL}')
    try:
        page.goto(LOGIN_URL, timeout=30000, wait_until='commit')
        time.sleep(5)
        current_url = page.url
        title = page.title()
        print(f'[登录] 页面加载成功. URL: {current_url}, Title: {title}')

        body_text = ''
        try:
            body_text = page.inner_text('body')
        except Exception:
            pass

        if body_text.strip() or title:
            return True
    except Exception as e:
        print(f'[登录] 直接访问 {LOGIN_URL} 失败: {str(e)[:200]}')

    for redirect_url in REDIRECT_URLS:
        print(f'[登录] 尝试通过 {redirect_url} 触发重定向...')
        try:
            page.goto(redirect_url, timeout=20000, wait_until='commit')
            time.sleep(5)
            current_url = page.url
            print(f'[登录] 重定向后 URL: {current_url}')

            if ('2.2.2.2' in current_url
                    or 'login' in current_url.lower()
                    or 'portal' in current_url.lower()):
                print('[登录] 成功重定向到登录页!')
                return True

            inputs = page.query_selector_all('input')
            if len(inputs) >= 2:
                print(f'[登录] 页面包含 {len(inputs)} 个输入框，可能是登录页')
                return True
        except Exception as e:
            err_str = str(e)
            if 'ERR_ABORTED' in err_str:
                try:
                    current_url = page.url
                    print(f'[登录] 中断后 URL: {current_url}')
                    if ('2.2.2.2' in current_url
                            or 'login' in current_url.lower()
                            or 'portal' in current_url.lower()):
                        return True
                except Exception:
                    pass
                continue
            print(f'[登录] {redirect_url} 访问失败: {err_str[:200]}')

    print('[登录] 所有方式均未能到达登录页')
    return False


def find_captcha_input_by_image(page, captcha_img):
    """通过验证码图片元素定位相邻的验证码输入框"""
    if not captcha_img:
        return None
    try:
        # 取验证码图片的几何中心，找垂直距离 120px 内、水平最近的可见 input
        js_script = """
        el => {
            const rect = el.getBoundingClientRect();
            const inputs = Array.from(document.querySelectorAll('input'));
            let best = null;
            let bestDist = Infinity;
            for (const inp of inputs) {
                if (inp.offsetParent === null) continue;
                const ir = inp.getBoundingClientRect();
                const dx = Math.abs((ir.left + ir.width/2) - (rect.left + rect.width/2));
                const dy = Math.abs((ir.top + ir.height/2) - (rect.top + rect.height/2));
                if (dy > 120) continue;
                const dist = dx + dy * 2;
                if (dist < bestDist) {
                    bestDist = dist;
                    best = inp;
                }
            }
            return best;
        }
        """
        handle = captcha_img.evaluate_handle(js_script)
        if handle:
            element = handle.as_element()
            if element and element.is_visible():
                return element
    except Exception as e:
        print(f'[验证码] 通过图片定位输入框失败: {e}')
    return None


def try_ocr_captcha(image_path):
    """尝试使用 ddddocr 自动识别验证码（仅 --auto 模式使用）"""
    try:
        import ddddocr
        ocr = ddddocr.DdddOcr(show_ad=False)
        with open(image_path, 'rb') as f:
            img_bytes = f.read()
        result = ocr.classification(img_bytes)
        if result and result.strip():
            return result.strip()
        return None
    except ImportError:
        print('[验证码] ddddocr 未安装，无法自动识别')
        return None
    except Exception as e:
        print(f'[验证码] OCR 识别出错: {e}')
        return None


def handle_captcha(page, captcha_input, captcha_img, retry_num, max_ocr_retries=5):
    """全自动处理验证码：使用 ddddocr 自动识别，失败时自动刷新重试

    返回: (success: bool, captcha_text: str or None)
    """
    captcha_screenshot = os.path.join(BASE_DIR, f'captcha_retry{retry_num}.png')
    print('[验证码] 开始自动识别（ddddocr，无需人工输入）...')

    for attempt in range(1, max_ocr_retries + 1):
        if captcha_img:
            try:
                captcha_img.screenshot(path=captcha_screenshot)
            except Exception:
                page.screenshot(path=captcha_screenshot)
        else:
            page.screenshot(path=captcha_screenshot)

        captcha_text = try_ocr_captcha(captcha_screenshot)

        if (captcha_text and len(captcha_text) >= 2
                and all(c.isalnum() for c in captcha_text)):
            try:
                captcha_input.fill(captcha_text)
                print(f'[验证码] ✅ 第 {attempt} 次识别成功: {captcha_text}')
                return True, captcha_text
            except Exception as e:
                print(f'[验证码] 填入失败: {e}')
        else:
            if captcha_text:
                print(f'[验证码] 第 {attempt} 次识别结果无效（含非字母数字字符）: {captcha_text}')
            else:
                print(f'[验证码] 第 {attempt} 次识别失败或结果过短')

        if attempt < max_ocr_retries:
            if captcha_img:
                try:
                    captcha_img.click()
                    time.sleep(2)
                    print(f'[验证码] 已刷新验证码图片，准备第 {attempt + 1} 次识别...')
                except Exception:
                    print('[验证码] 刷新验证码图片失败')
            else:
                print('[验证码] 未找到验证码图片元素，无法刷新')

    print(f'[验证码] ❌ 达到最大重试次数 ({max_ocr_retries})，识别失败')
    return False, None


def do_campus_login(page, retry_num):
    """执行校园网登录"""
    print('\n==================================================')
    print(f'[登录] 第 {retry_num} 次尝试登录校园网...')
    print('==================================================')

    step_log(1, TOTAL_STEPS, 'start', '正在导航到校园网登录页面...')
    if not try_reach_login_page(page, retry_num):
        step_log(1, TOTAL_STEPS, 'fail', '无法到达登录页面')
        screenshot_path = os.path.join(BASE_DIR, f'login_fail_retry{retry_num}.png')
        try:
            page.screenshot(path=screenshot_path)
            print(f'[登录] 已保存失败截图: {screenshot_path}')
        except Exception:
            pass
        return False
    step_log(1, TOTAL_STEPS, 'ok', '成功到达登录页面')

    current_url = page.url
    title = page.title()
    print(f'[登录] 当前页面 URL: {current_url}')
    print(f'[登录] 当前页面标题: {title}')

    screenshot_path = os.path.join(BASE_DIR, f'login_page_retry{retry_num}.png')
    try:
        page.screenshot(path=screenshot_path)
        print(f'[登录] 已保存截图: {screenshot_path}')
    except Exception:
        pass

    try:
        page_text = page.inner_text('body')
        print(f'[登录] 页面文本 (前500字): {page_text[:500]}')
    except Exception:
        print('[登录] 无法获取页面文本')

    # ---------------- 步骤 2：填账号 ----------------
    step_log(2, TOTAL_STEPS, 'start', '正在填入账号...')
    account_filled = False
    password_filled = False

    inputs = page.query_selector_all('input')
    print(f'[登录] 页面共有 {len(inputs)} 个 input 元素:')
    for i, inp in enumerate(inputs):
        inp_type = inp.get_attribute('type') or ''
        inp_name = inp.get_attribute('name') or ''
        inp_placeholder = inp.get_attribute('placeholder') or ''
        inp_id = inp.get_attribute('id') or ''
        print(f'  input[{i}]: type={inp_type}, name={inp_name}, '
              f'placeholder={inp_placeholder}, id={inp_id}')

    for selector in ACCOUNT_SELECTORS:
        try:
            el = page.query_selector(selector)
            if el and el.is_visible():
                el.fill(ACCOUNT)
                print(f'[登录] 账号已填入 (selector: {selector}): {ACCOUNT}')
                account_filled = True
                break
        except Exception:
            continue

    for selector in PASSWORD_SELECTORS:
        try:
            el = page.query_selector(selector)
            if el and el.is_visible():
                el.fill(PASSWORD)
                print(f'[登录] 密码已填入 (selector: {selector}): ***')
                password_filled = True
                break
        except Exception:
            continue

    # 选择器都没命中时，按 type/placeholder 逐个推断
    if not (account_filled and password_filled):
        text_inputs_seen = 0
        for i, inp in enumerate(inputs):
            try:
                inp_type = (inp.get_attribute('type') or 'text').lower()
                inp_name = (inp.get_attribute('name') or '').lower()
                inp_placeholder = (inp.get_attribute('placeholder') or '').lower()

                if inp_type == 'password':
                    if not password_filled:
                        inp.fill(PASSWORD)
                        print(f'[登录] 密码已填入 input[{i}]')
                        password_filled = True
                    continue

                if not inp.is_visible():
                    continue

                if inp_type in ('text', 'tel', 'email', ''):
                    # 排除验证码框，避免把账号填进验证码
                    is_captcha_attr = ('密码' in inp_placeholder
                                       or '验证' in inp_placeholder
                                       or 'code' in inp_name)
                    if is_captcha_attr:
                        continue
                    if not account_filled:
                        inp.fill(ACCOUNT)
                        print(f'[登录] 账号已填入 input[{i}]')
                        account_filled = True
                        text_inputs_seen += 1
            except Exception:
                continue

    if account_filled:
        step_log(2, TOTAL_STEPS, 'ok', f'账号已填入: {ACCOUNT}')
    else:
        step_log(2, TOTAL_STEPS, 'fail', '账号填入失败')

    # ---------------- 步骤 3：确认密码 ----------------
    step_log(3, TOTAL_STEPS, 'start', '正在填入密码...')
    if password_filled:
        step_log(3, TOTAL_STEPS, 'ok', '密码已填入: ***')
    else:
        step_log(3, TOTAL_STEPS, 'fail', '密码填入失败')

    # ---------------- 步骤 4：验证码 ----------------
    step_log(4, TOTAL_STEPS, 'start', '正在检测并处理验证码...')
    captcha_img = None
    captcha_input = None
    captcha_filled = False
    captcha_text = None

    for selector in CAPTCHA_IMG_SELECTORS:
        try:
            el = page.query_selector(selector)
            if el and el.is_visible():
                captcha_img = el
                print(f'[登录] 找到验证码图片 (selector: {selector})')
                break
        except Exception:
            continue

    for selector in CAPTCHA_INPUT_SELECTORS:
        try:
            el = page.query_selector(selector)
            if el and el.is_visible():
                captcha_input = el
                print(f'[登录] 找到验证码输入框 (selector: {selector})')
                break
        except Exception:
            continue

    if not captcha_input and captcha_img:
        captcha_input = find_captcha_input_by_image(page, captcha_img)
        if captcha_input:
            print('[登录] 通过验证码图片定位到验证码输入框')

    # 仍找不到：退化为「可见文本框里的第 2 个」当作验证码框
    if not captcha_input:
        text_inputs = []
        for i, inp in enumerate(inputs):
            try:
                inp_type = (inp.get_attribute('type') or 'text').lower()
                if inp_type in ('text', '', 'tel') and inp.is_visible():
                    text_inputs.append((i, inp))
            except Exception:
                continue
        for idx, (i, inp) in enumerate(text_inputs):
            inp_name = (inp.get_attribute('name') or '').lower()
            if idx == 1 and not captcha_input:
                captcha_input = inp
                print(f'[登录] 找到验证码输入框 (input[{i}]: name={inp_name}, '
                      f'order={idx})')
                break

    if captcha_input:
        captcha_filled, captcha_text = handle_captcha(
            page, captcha_input, captcha_img, retry_num, max_ocr_retries=5)
        if captcha_filled:
            print(f'[登录] 验证码处理结果: ✅ 已填入 {captcha_text}')
            step_log(4, TOTAL_STEPS, 'ok', f'验证码识别成功: {captcha_text}')
        else:
            print('[登录] 验证码处理结果: ❌ 未填入')
            step_log(4, TOTAL_STEPS, 'fail', '验证码识别失败')
    else:
        print('[登录] 未检测到验证码输入框，跳过验证码步骤')
        step_log(4, TOTAL_STEPS, 'info', '页面无验证码（跳过）')

    # ---------------- 步骤 5：提交前校验 ----------------
    step_log(5, TOTAL_STEPS, 'start', '正在校验字段完整性...')
    print('  [校验] 登录前字段完整性检查')
    print(f'  账号:   {"✅ 已填入" if account_filled else "❌ 未填入"}')
    print(f'  密码:   {"✅ 已填入" if password_filled else "❌ 未填入"}')
    if captcha_input:
        if captcha_filled:
            print(f'  验证码: ✅ 已填入 ({captcha_text})')
        else:
            print('  验证码: ❌ 未填入')
    else:
        print('  验证码: ➖ 页面无验证码（跳过）')
    print('==================================================')

    if not (account_filled and password_filled):
        step_log(5, TOTAL_STEPS, 'fail', '账号或密码未填入，无法登录')
        print('[登录] ❌ 账号或密码未填入，无法登录')
        return False

    if captcha_input and not captcha_filled:
        step_log(5, TOTAL_STEPS, 'fail', '验证码未识别成功，无法登录')
        print('[登录] ❌ 验证码未识别成功，无法登录（保证三字段全部有效才提交）')
        return False

    step_log(5, TOTAL_STEPS, 'ok', '所有字段校验通过')

    # ---------------- 步骤 6：点击登录 ----------------
    step_log(6, TOTAL_STEPS, 'start', '正在点击登录按钮...')
    before_login_url = page.url
    print(f'[登录] 登录前 URL: {before_login_url}')

    login_clicked = False
    for selector in LOGIN_BUTTON_SELECTORS:
        try:
            el = page.query_selector(selector)
            if el and el.is_visible():
                el.click()
                print(f'[登录] 已点击登录按钮 (selector: {selector})')
                login_clicked = True
                break
        except Exception:
            continue

    if not login_clicked:
        buttons = page.query_selector_all(
            "button, a, input[type='button'], input[type='submit']")
        for btn in buttons:
            try:
                if btn.tag_name in ('button', 'a'):
                    text = btn.inner_text()
                else:
                    text = btn.get_attribute('value') or ''

                if text and any(kw in text for kw in LOGIN_BUTTON_TEXTS):
                    btn.click()
                    print(f'[登录] 已点击登录按钮 (text: {text})')
                    login_clicked = True
                    break
                elif text and 'login' in text.lower():
                    btn.click()
                    print(f'[登录] 已点击登录按钮 (text: {text})')
                    login_clicked = True
                    break
            except Exception:
                continue

    if not login_clicked:
        page.keyboard.press('Enter')
        print('[登录] 已按回车键尝试提交')

    if login_clicked:
        step_log(6, TOTAL_STEPS, 'ok', '已点击登录按钮')
    else:
        step_log(6, TOTAL_STEPS, 'info', '已按回车键提交')

    # ---------------- 步骤 7：等待响应 ----------------
    step_log(7, TOTAL_STEPS, 'wait', '等待登录响应...')
    time.sleep(5)

    after_login_screenshot = os.path.join(BASE_DIR, f'after_login_retry{retry_num}.png')
    try:
        page.screenshot(path=after_login_screenshot)
        print(f'[登录] 登录后截图已保存: {after_login_screenshot}')
    except Exception:
        pass

    after_url = page.url
    after_title = page.title()
    print(f'[登录] 登录后 URL: {after_url}')
    print(f'[登录] 登录后标题: {after_title}')

    # ---------------- 步骤 8：验证结果 ----------------
    step_log(8, TOTAL_STEPS, 'start', '正在验证登录结果...')
    login_success = False
    success_indicators = [
        after_url != before_login_url,
        'success' in after_url.lower(),
        'logout' in after_url.lower() or '退出' in after_url.lower(),
        'online' in after_url.lower() or '在线' in after_url.lower(),
    ]

    if any(success_indicators):
        login_success = True
        print('\n==================================================')
        print('  ✅✅✅ 登录成功！')
        print(f'  URL 已跳转: {before_login_url} → {after_url}')
        print('==================================================\n')
        step_log(8, TOTAL_STEPS, 'ok', '登录成功！页面已跳转')
        return True

    print('[登录] 登录后仍在登录页（URL 未变化），登录可能失败，等待复检确认')
    step_log(8, TOTAL_STEPS, 'info', 'URL未变化，等待网络复检确认')
    return True


def play_bilibili_video(page):
    """在B站播放视频"""
    print('\n[播放] 正在打开B站并播放视频...')

    current_url = page.url
    if 'bilibili' not in current_url.lower():
        try:
            page.goto(BILIBILI_URL, timeout=30000, wait_until='commit')
            time.sleep(5)
        except Exception as e:
            print(f'[播放] 导航到B站失败: {str(e)[:200]}')
            return False
    else:
        print('[播放] 已在B站页面，无需重新导航')

    time.sleep(3)

    for selector in VIDEO_SELECTORS:
        els = page.query_selector_all(selector)
        if els and len(els) > 0:
            els[0].click()
            print(f'[播放] 已点击推荐视频 (selector: {selector})')
            time.sleep(5)
            play_screenshot = os.path.join(BASE_DIR, 'bilibili_playing.png')
            page.screenshot(path=play_screenshot)
            print(f'[播放] 播放页面截图已保存: {play_screenshot}')
            return True

    print('[播放] 未找到可点击的推荐视频，保持在B站首页')
    homepage_screenshot = os.path.join(BASE_DIR, 'bilibili_homepage.png')
    page.screenshot(path=homepage_screenshot)
    print(f'[播放] B站首页截图已保存: {homepage_screenshot}')
    return True


def run_login_flow():
    """主登录流程：检测网络 → 登录 → 播放视频"""
    banner('校园网自动检测与登录程序启动')
    print(f'  账号: {ACCOUNT}')
    print(f'  登录URL: {LOGIN_URL}')
    print(f'  测试URL: {TEST_URL}')
    print(f'  最大重试: {MAX_RETRIES} 次')
    print(f'  自动模式: {"是" if AUTO_MODE else "否"}')

    browser = None
    try:
        with sync_playwright() as p:
            print('\n[启动] 正在启动 Edge 浏览器...')
            browser = p.chromium.launch(headless=False, channel='msedge')
            page = browser.new_page()
            page.set_default_timeout(30000)

            banner('步骤 1/3: 检测当前网络状态', '-')
            print('>>> 正在检测网络是否正常...')
            network_ok = check_network(page)

            if network_ok:
                banner('🎉 网络正常！无需登录')
                print('>>> 直接播放B站视频...')
                play_bilibili_video(page)
                banner('✅ 已在B站播放视频。本次任务圆满结束。')
                save_run_time()
                try:
                    import winsound
                    winsound.MessageBeep(winsound.MB_ICONEXCLAMATION)
                except Exception:
                    pass
                browser.close()
                return

            print('\n❌ 检测到无法联网，开始校园网登录流程...')

            for retry in range(1, MAX_RETRIES + 1):
                do_campus_login(page, retry)

                print(f'\n[等待] 登录后等待 {WAIT_AFTER_LOGIN} 秒让网络连接建立...')
                time.sleep(WAIT_AFTER_LOGIN)

                print(f'>>> 第 {retry} 次登录后网络检测')
                network_ok = check_network(page)

                if network_ok:
                    print()
                    print('=' * 60)
                    print('  🎉  校园网登录成功！网络已恢复！')
                    print('=' * 60)
                    play_bilibili_video(page)
                    print()
                    print('=' * 60)
                    print('  ✅  已在B站播放视频。本次任务圆满结束。')
                    print('=' * 60)
                    save_run_time()
                    try:
                        import winsound
                        winsound.MessageBeep(winsound.MB_ICONEXCLAMATION)
                    except Exception:
                        pass
                    browser.close()
                    return

                print(f'\n❌ 第 {retry} 次登录后仍无法联网')
                if retry < MAX_RETRIES:
                    print(f'>>> 准备第 {retry + 1} 次重试...')
                else:
                    print()
                    print('=' * 60)
                    print(f'  ❌  已达到最大重试次数 ({MAX_RETRIES} 次)，仍无法联网。')
                    print('=' * 60)
                    save_run_time()
                    try:
                        import winsound
                        winsound.MessageBeep(winsound.MB_ICONHAND)
                    except Exception:
                        pass

            browser.close()
    except Exception as e:
        print(f'\n[错误] 程序异常: {str(e)[:300]}')
        try:
            if browser:
                browser.close()
        except Exception:
            pass


def show_menu():
    """显示交互菜单"""
    dev_banner()
    enabled, reg_value = is_autostart_enabled()
    print()
    print('=' * 60)
    print('  校园网自动检测与登录程序')
    print('=' * 60)
    print(f'  开机自启动: {"✅ 已开启" if enabled else "❌ 未开启"}')
    print()
    print('  请选择操作:')
    print('    1. 立即执行网络检测与登录')
    print('    2. 开启开机自启动')
    print('    3. 关闭开机自启动')
    print('    4. 查看自启动状态')
    print('    5. 查看下次检测时间')
    print('    0. 退出')
    print('-' * 60)


def main():
    if '--auto' in sys.argv:
        global AUTO_MODE
        AUTO_MODE = True
        os.system('cls' if os.name == 'nt' else 'clear')
        banner('校园网自动检测程序启动 (自动模式)', '#')
        dev_banner()
        print(f'  账号: {ACCOUNT}')
        print(f'  时间: {time.strftime("%Y-%m-%d %H:%M:%S")}')
        print(f'  日志: {os.path.join(BASE_DIR, "login_steps.log")}')
        print()
        print('[等待] 等待 10 秒让系统网络初始化...')
        time.sleep(10)
        run_login_flow()
        show_next_check_time()
        print()
        banner('程序执行完毕，窗口 30 秒后自动关闭', '#')
        print(f'  详细步骤日志: {os.path.join(BASE_DIR, "login_steps.log")}')
        print(f'  监控日志: {os.path.join(BASE_DIR, "monitor.log")}')
        print()
        for i in range(30, 0, -1):
            print(f'\r  倒计时: {i:2d} 秒', end='', flush=True)
            time.sleep(1)
        print('\r                      \r')
        return

    if '--enable-autostart' in sys.argv:
        enable_autostart()
        return

    if '--disable-autostart' in sys.argv:
        disable_autostart()
        return

    while True:
        try:
            show_menu()
            choice = input('  请输入选项 (0-5): ').strip()

            if choice == '1':
                run_login_flow()
                show_next_check_time()
                input('\n  按回车键返回菜单...')
            elif choice == '2':
                enable_autostart()
                input('\n  按回车键返回菜单...')
            elif choice == '3':
                disable_autostart()
                input('\n  按回车键返回菜单...')
            elif choice == '4':
                enabled, reg_value = is_autostart_enabled()
                print()
                if enabled:
                    print('  ✅ 开机自启动已开启')
                    print(f'  注册表项: HKCU\\{AUTOSTART_REG_KEY}')
                    print(f'  值名称: {AUTOSTART_REG_NAME}')
                    print(f'  启动命令: {reg_value}')
                else:
                    print('  ❌ 开机自启动未开启')
                input('\n  按回车键返回菜单...')
            elif choice == '5':
                show_next_check_time()
                input('\n  按回车键返回菜单...')
            elif choice == '0':
                print('  再见!')
                return
            else:
                print('  无效选项，请重新输入。')
        except (EOFError, KeyboardInterrupt):
            print('\n  再见!')
            return


if __name__ == '__main__':
    main()
