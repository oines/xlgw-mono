import { useState, type FormEvent } from "react";
import { ArrowUpRight, Eye, EyeOff, Waves } from "lucide-react";
import { useSession } from "../lib/session";
import { Button, ErrorNotice, Field } from "../components/ui";

export function LoginPage() {
  const { login, school } = useSession();
  const [account, setAccount] = useState("");
  const [password, setPassword] = useState("");
  const [showPassword, setShowPassword] = useState(false);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<Error | null>(null);
  async function submit(event: FormEvent) {
    event.preventDefault();
    setError(null);
    setBusy(true);
    try {
      await login(account.trim(), password);
    } catch (caught) {
      setError(caught as Error);
    } finally {
      setBusy(false);
    }
  }
  return (
    <main className="login-page">
      <section className="login-story">
        <div className="login-brand">
          <Waves size={28} />
          <strong>心灵港湾</strong>
        </div>
        <div className="login-story-body">
          <div className="story-rule" />
          <h1>
            认真倾听，
            <br />
            一起向前。
          </h1>
          <p>
            从一次倾诉，到一次及时的回应。
            <br />
            在校园里，把支持带给需要的同学。
          </p>
          <div className="story-signature">
            校园心理支持 · 工作空间 <ArrowUpRight size={17} />
          </div>
        </div>
        <footer>{school?.name || "心灵港湾校园支持平台"}</footer>
      </section>
      <section className="login-form-side">
        <div className="login-form-wrap">
          <span className="eyebrow">欢迎回来</span>
          <h2>登录工作台</h2>
          <p className="login-description">
            管理你的接待安排，继续尚未结束的关心。
          </p>
          <form onSubmit={submit}>
            <ErrorNotice error={error} />
            <Field label="账号">
              <input
                autoComplete="username"
                autoFocus
                required
                minLength={4}
                value={account}
                onChange={(event) => setAccount(event.target.value)}
                placeholder="请输入工作账号"
              />
            </Field>
            <Field label="密码">
              <span className="password-input">
                <input
                  autoComplete="current-password"
                  required
                  minLength={8}
                  type={showPassword ? "text" : "password"}
                  value={password}
                  onChange={(event) => setPassword(event.target.value)}
                  placeholder="请输入密码"
                />
                <button
                  type="button"
                  className="icon-button"
                  aria-label={showPassword ? "隐藏密码" : "显示密码"}
                  onClick={() => setShowPassword(!showPassword)}
                >
                  {showPassword ? <EyeOff size={18} /> : <Eye size={18} />}
                </button>
              </span>
            </Field>
            <Button
              type="submit"
              tone="primary"
              busy={busy}
              className="login-submit"
            >
              登录工作台
            </Button>
          </form>
          <div className="login-help">
            账号由学校管理人员开通。
            {school?.contact
              ? `如需帮助，请联系 ${school.contact}。`
              : "忘记密码或需要开通身份，请联系学校管理人员。"}
          </div>
          {school?.initialized === false && (
            <div className="setup-notice">
              学校工作空间尚未初始化，请先由部署管理员创建初始管理账号。
            </div>
          )}
        </div>
        <p className="login-footnote">
          请妥善保管账号，并在共用设备上使用后退出登录。
        </p>
      </section>
    </main>
  );
}
