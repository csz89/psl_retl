// Настройки сайта. Этот файл публичный: сюда нельзя класть ничего секретного.
// Client ID от Google это публичный идентификатор, он не секрет (секретом был бы Client secret, он сайту не нужен).
window.PSL_CONFIG = {
  // Client ID из Google Cloud Console (раздел Clients). Пока строка пустая, кнопка «Войти через Google» на публичном сайте неактивна.
  googleClientId: "766175831745-3mu7gqfqck6jf6fkvik2to685jl6ark1.apps.googleusercontent.com",

  // Онлайн-батлы (Supabase). Пока пусто, страница «Онлайн» пишет, что режим не подключён. Оба значения публичные, секретов здесь нет.
  // Project URL выглядит как https://abcdefgh.supabase.co, anon public key это длинная строка из Project Settings -> API.
  supabaseUrl: "https://tzqawpsgogcjxqtdicou.supabase.co",
  supabaseAnonKey: "sb_publishable_esleR0YJzJECoHy1Ft7QCA_eHUqDIgG",

  // Как принимать оплату (нужны ключи в переменных окружения Vercel, см. README). Пока список пустой, цены показываются, но купить нельзя.
  // Допустимые значения: "stripe" (карты, много валют), "liqpay" (гривна, доллар, евро).
  payProviders: ["liqpay"],

  // Данные продавца для страницы «Условия покупки» (их требует платёжная система). Заполните своими.
  seller: {name: "", taxId: "", address: "", email: "", phone: ""},

  // Почта для вопросов по данным (показывается на странице «Конфиденциальность»). Можно оставить пустой.
  contactEmail: "",
};
