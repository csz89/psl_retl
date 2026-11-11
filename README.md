# PSL Rater

Статический сайт: один `index.html` + `config.js`. Сервера и сборки нет, поэтому он без настроек работает на Vercel, GitHub Pages и любом хостинге.

| Файл | Зачем |
|---|---|
| `index.html` | весь сайт (страницы, модель, аккаунты) |
| `config.js` | **сюда вписывается Google Client ID** |
| `serve.js` | локальный сервер для проверки на своём компьютере (`node serve.js`, затем http://localhost:5173) |
| `.gitignore` | не пускает в репозиторий фото |

## 1. Репозиторий на GitHub

**Сначала про фото.** В локальном коммите этой папки уже лежит файл `03b33f…jpg` с лицом человека, а рядом есть `parenL.jpg`. Если просто сделать `git push`, эти фото станут публичными вместе с историей. Поэтому самый безопасный путь начать репозиторий заново, пока ничего не отправлено:

```powershell
cd D:\mogs
Remove-Item -Recurse -Force .git
git init -b main
git add .
git status        # проверьте список: только index.html, config.js, serve.js, README.md, .gitignore
git commit -m "PSL Rater"
```

Затем на github.com создайте пустой репозиторий (например `psl-rater`, без README и .gitignore) и:

```powershell
git remote add origin https://github.com/ВАШ_ЛОГИН/psl-rater.git
git push -u origin main
```

Файлы `*.jpg`, `*.png` и т. п. теперь игнорируются, но всё равно проверяйте `git status` перед каждым коммитом.

## 2. Vercel

1. vercel.com → **Add New… → Project** → войдите через GitHub и выберите репозиторий.
2. **Framework Preset: Other.** Поля Build Command, Output Directory и Install Command оставьте пустыми.
3. **Deploy.** Через минуту сайт будет доступен по адресу вида `https://psl-rater.vercel.app`. Он обновляется сам после каждого `git push` в ветку `main`.

## 3. Вход через Google

Нужен бесплатный Client ID. Секретный ключ не нужен.

1. Откройте https://console.cloud.google.com и создайте проект.
2. **APIs & Services → OAuth consent screen** (в новом интерфейсе Google Auth Platform):
   - Тип пользователей: **External**.
   - Название приложения, ваша почта поддержки и почта разработчика.
   - Ссылка на политику конфиденциальности (если просят): `https://ВАШ-САЙТ.vercel.app/#/privacy`.
   - Пока приложение в режиме **Testing**, войти смогут только аккаунты из списка *Test users* (добавьте свой). Чтобы пускать всех, нажмите **Publish app**: для базовых данных (email, profile, openid) проверка Google не требуется.
3. **Credentials → Create credentials → OAuth client ID → Web application.**
   - **Authorized JavaScript origins**: добавьте `https://ВАШ-САЙТ.vercel.app` (без `/` в конце и без пути) и для локальной проверки `http://localhost:5173`.
   - **Authorized redirect URIs** оставьте пустым: кнопка работает через всплывающее окно.
4. Скопируйте **Client ID** (оканчивается на `.apps.googleusercontent.com`) и вставьте в `config.js`:

   ```js
   googleClientId: "1234567890-abcdefg.apps.googleusercontent.com",
   ```
5. `git add config.js && git commit -m "Google Client ID" && git push`. Vercel обновит сайт, и кнопка станет активной.

Изменения в консоли Google иногда применяются не сразу (от нескольких минут до пары часов).

### Если не работает

| Симптом | Причина |
|---|---|
| `origin_mismatch` или «The given origin is not allowed» | адрес сайта не добавлен в Authorized JavaScript origins или написан иначе (http вместо https, лишний `/`, другой поддомен) |
| «Доступ заблокирован: приложение не прошло проверку» | приложение в режиме Testing, а вашего аккаунта нет в Test users, либо не нажата Publish app |
| кнопка Google серая, написано «не настроен» | `config.js` пустой или не попал в репозиторий |
| работает на основном адресе, но не на ссылке предпросмотра | у каждой ветки/коммита на Vercel свой адрес, в Google добавлен только основной |
| не работает при открытии `index.html` двойным щелчком | Google не пускает страницы с `file://`, запустите `node serve.js` |

Если Google не принимает адрес `*.vercel.app` на экране согласия, подключите свой домен (Vercel → Settings → Domains) и используйте его.

## 4. Что важно знать

- **Аккаунты локальные.** Они хранятся в браузере каждого пользователя (`localStorage`), а не на сервере: профиль не переносится между устройствами, а Google-вход подтверждает личность только внутри этого браузера. Токен Google не проверяется на сервере (сервера нет), поэтому это не защита данных, а удобство. Настоящие аккаунты потребуют серверной части (база данных и проверка токена).
- **Лицензия датасета.** Модель обучена на SCUT-FBP5500, который выпущен для научных целей. Прежде чем открывать сайт публично или монетизировать, проверьте условия набора: https://github.com/HCIILAB/SCUT-FBP5500-Database-Release
- **Фото не хранятся и не отправляются:** всё считается в браузере. Но сайт подгружает библиотеку и модели с `cdn.jsdelivr.net` и `storage.googleapis.com`, а шрифт с `fonts.googleapis.com`.
- Развлекательный инструмент: оценка отражает вкус 60 оценщиков, а не объективную истину.
