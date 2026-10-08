// routes_account.v is the V transpile of routes/account.py: account
// administration (account, users, bots, styles, join code, bans).
module campfile

import json
import campfire as c
import database

fn admin_or_403(mut d database.DB, uid i64) bool {
	row := user(mut d, uid) or { return false }
	return row.role == c.role_admin
}

pub struct UserJson {
pub mut:
	id            i64
	name          string
	email_address string
	role          i64
	status        i64
}

fn user_json(u UserRow) UserJson {
	return UserJson{
		id:            u.id
		name:          u.name
		email_address: u.email_address
		role:          u.role
		status:        u.status
	}
}

pub struct AccountView {
pub mut:
	name           string
	join_url       string
	can_administer bool
	administrators []UserJson
	members        []UserJson
}

// account_show serves the account overview with administrators and members.
pub fn account_show(mut d database.DB, r Req) Resp {
	uid := actor_or_login(r)
	if uid == -1 {
		return login_redirect()
	}
	me := user(mut d, uid) or { return err_resp('not found', 404) }
	account := account_row(mut d) or { return err_resp('not found', 404) }
	mut statement :=
		"SELECT id,coalesce(name,''),coalesce(email_address,''),role,status FROM users WHERE role != " +
		c.role_bot.str() + ' AND status '
	statement += if me.role == c.role_admin { 'IN (0,2)' } else { '= 0' }
	statement += ' ORDER BY lower(name) LIMIT 500'
	rows := d.query_all(statement, []) or { return err_resp('not found', 404) }
	mut admins := []UserJson{}
	mut members := []UserJson{}
	for row in rows {
		u := user_json(UserRow{
			id:            row_i64(row, 0)
			name:          row_str(row, 1)
			email_address: row_str(row, 2)
			role:          row_i64(row, 3)
			status:        row_i64(row, 4)
		})
		if u.role == c.role_admin {
			admins << u
		} else {
			members << u
		}
	}
	return present(AccountView{
		name:           account.name
		join_url:       '/join/' + account.join_code
		can_administer: me.role == c.role_admin
		administrators: admins
		members:        members
	})
}

struct AccountSettingsInner {
pub mut:
	restrict_room_creation_to_administrators bool
}

struct AccountForm {
pub mut:
	name     string
	settings AccountSettingsInner
}

struct AccountPayload {
pub mut:
	name    string
	account AccountForm
}

// account_update patches the account name and settings.
pub fn account_update(mut d database.DB, r Req) Resp {
	uid := actor_or_login(r)
	if uid == -1 {
		return login_redirect()
	}
	if !admin_or_403(mut d, uid) {
		return err_resp('forbidden', 403)
	}
	account := account_row(mut d) or { return err_resp('not found', 404) }
	mut name := ''
	mut has_name := false
	mut restrict := false
	mut has_settings := false
	if r.body != '' {
		outer := json.decode(AccountPayload, r.body) or { AccountPayload{} }
		form := if outer.account.name != '' || r.body.contains('"settings"') {
			outer.account
		} else {
			AccountForm{
				name: outer.name
			}
		}
		if r.body.contains('"name"') {
			name = form.name
			has_name = true
		}
		if r.body.contains('"settings"') {
			restrict = form.settings.restrict_room_creation_to_administrators || outer.name == ''
			has_settings = true
		}
	}
	if 'account[settings][restrict_room_creation_to_administrators]' in r.form {
		restrict = true
		has_settings = true
	}
	update_account(mut d, account.id, name, has_name, restrict, has_settings, now_epoch()) or {
		return err_resp('unprocessable', 422)
	}
	updated := account_row(mut d) or { return err_resp('not found', 404) }
	return present(AccountUpdated{
		name:     updated.name
		settings: account_settings(updated).restrict_room_creation_to_administrators
	})
}

pub struct AccountUpdated {
pub mut:
	name     string
	settings bool
}

// account_user changes a role or deactivates a user.
pub fn account_user(mut d database.DB, r Req) Resp {
	uid := actor_or_login(r)
	if uid == -1 {
		return login_redirect()
	}
	if !admin_or_403(mut d, uid) {
		return err_resp('forbidden', 403)
	}
	other := int_path_arg(r, 'id')
	row := user(mut d, other) or { return err_resp('not found', 404) }
	if row.status != 0 {
		return err_resp('not found', 404)
	}
	if r.method == 'DELETE' {
		deactivate_user(mut d, other, now_epoch()) or { return err_resp('unprocessable', 422) }
		return present(UserStatus{ id: other, status: 1 })
	}
	mut role := c.role_member
	if r.body != '' {
		payload := json.decode(UserRolePayload, r.body) or { UserRolePayload{} }
		nested := payload.user.role
		top := payload.role
		want := if nested != '' { nested } else { top }
		if want == 'administrator' {
			role = c.role_admin
		}
	}
	set_role(mut d, other, role, now_epoch()) or { return err_resp('unprocessable', 422) }
	return present(UserRole{ id: other, role: role })
}

struct UserRolePayload {
pub mut:
	role string
	user UserRolePayloadInner
}

struct UserRolePayloadInner {
pub mut:
	role string
}

pub struct UserStatus {
pub mut:
	id     i64
	status i64
}

pub struct UserRole {
pub mut:
	id   i64
	role i64
}

pub struct BotView {
pub mut:
	id      i64
	name    string
	key     string
	webhook string
	rooms   []BotRoom
}

pub struct BotRoom {
pub mut:
	id   i64
	name string
}

// bots_list lists bots with keys, webhooks and rooms.
pub fn bots_list(mut d database.DB, r Req) Resp {
	uid := actor_or_login(r)
	if uid == -1 {
		return login_redirect()
	}
	if !admin_or_403(mut d, uid) {
		return err_resp('forbidden', 403)
	}
	rows := d.query_all("SELECT id,coalesce(name,'') FROM users WHERE role=? AND status=0 ORDER BY lower(name)", [
		c.role_bot.str(),
	]) or { return err_resp('not found', 404) }
	mut out := []BotView{}
	for b in rows {
		bid := row_i64(b, 0)
		mut brooms := []BotRoom{}
		for rm in d.query_all("SELECT r.id,coalesce(r.name,'') FROM rooms r JOIN memberships m ON m.room_id=r.id WHERE m.user_id=? ORDER BY r.id", [
			bid.str(),
		]) or { [] } {
			brooms << BotRoom{
				id:   row_i64(rm, 0)
				name: row_str(rm, 1)
			}
		}
		out << BotView{
			id:      bid
			name:    row_str(b, 1)
			key:     c.bot_key_of(bid, bot_token_of(mut d, bid))
			webhook: bot_webhook(mut d, bid)
			rooms:   brooms
		}
	}
	return present(out)
}

// bot_new_form serves the new-bot form data.
pub fn bot_new_form(mut d database.DB, r Req) Resp {
	uid := actor_or_login(r)
	if uid == -1 {
		return login_redirect()
	}
	if !admin_or_403(mut d, uid) {
		return err_resp('forbidden', 403)
	}
	return present(new_bot_form())
}

pub struct BotFormNew {
pub mut:
	new bool
}

fn new_bot_form() BotFormNew {
	return BotFormNew{
		new: true
	}
}

// bot_edit_form serves the edit-bot form data.
pub fn bot_edit_form(mut d database.DB, r Req) Resp {
	uid := actor_or_login(r)
	if uid == -1 {
		return login_redirect()
	}
	if !admin_or_403(mut d, uid) {
		return err_resp('forbidden', 403)
	}
	bid := int_path_arg(r, 'id')
	bot := user(mut d, bid) or { return err_resp('not found', 404) }
	if bot.role != c.role_bot {
		return err_resp('not found', 404)
	}
	return present(BotEditView{ id: bot.id, name: bot.name, webhook: bot_webhook(mut d, bot.id) })
}

pub struct BotEditView {
pub mut:
	id      i64
	name    string
	webhook string
}

struct BotPayload {
pub mut:
	name        string
	webhook_url string
	user        BotPayloadInner
}

struct BotPayloadInner {
pub mut:
	name        string
	webhook_url string
}

// bot_create creates a bot with an optional webhook.
pub fn bot_create(mut d database.DB, r Req) Resp {
	uid := actor_or_login(r)
	if uid == -1 {
		return login_redirect()
	}
	if !admin_or_403(mut d, uid) {
		return err_resp('forbidden', 403)
	}
	mut name := ''
	mut webhook := ''
	if r.body != '' {
		outer := json.decode(BotPayload, r.body) or { BotPayload{} }
		if outer.user.name != '' || outer.user.webhook_url != '' {
			name = outer.user.name.trim_space()
			webhook = outer.user.webhook_url
		} else {
			name = outer.name.trim_space()
			webhook = outer.webhook_url
		}
	}
	if name == '' {
		name = r.form['name'] or { '' }
	}
	if name == '' {
		return err_resp('name required', 422)
	}
	now := now_epoch()
	bot := create_user(mut d, name, '', '', c.role_bot, random_bot_token(), now) or {
		return err_resp('unprocessable', 422)
	}
	bot_upsert_webhook(mut d, bot.id, webhook, now)
	return created(BotCreated{
		id:   bot.id
		name: bot.name
		key:  c.bot_key_of(bot.id, bot_token_of(mut d, bot.id))
	})
}

pub struct BotCreated {
pub mut:
	id   i64
	name string
	key  string
}

fn random_bot_token() string {
	token := random_join_code()
	if token.len >= 12 {
		return token[..12]
	}
	return token
}

// bot_edit renames a bot, sets its webhook, or deactivates it.
pub fn bot_edit(mut d database.DB, r Req) Resp {
	uid := actor_or_login(r)
	if uid == -1 {
		return login_redirect()
	}
	if !admin_or_403(mut d, uid) {
		return err_resp('forbidden', 403)
	}
	bid := int_path_arg(r, 'id')
	mut bot := user(mut d, bid) or { return err_resp('not found', 404) }
	if bot.role != c.role_bot || bot.status != 0 {
		return err_resp('not found', 404)
	}
	if r.method == 'DELETE' {
		deactivate_user(mut d, bid, now_epoch()) or { return err_resp('unprocessable', 422) }
		return present(UserStatus{ id: bid, status: 1 })
	}
	mut webhook := ''
	mut has_webhook := false
	if r.body != '' {
		outer := json.decode(BotPayload, r.body) or { BotPayload{} }
		name := if outer.user.name != '' { outer.user.name } else { outer.name }
		if name != '' {
			db_update_user_name(mut d, bid, name, now_epoch())
			bot = user(mut d, bid) or { bot }
		}
		if outer.user.webhook_url != '' || outer.webhook_url != '' {
			webhook = if outer.user.webhook_url != '' {
				outer.user.webhook_url
			} else {
				outer.webhook_url
			}
			has_webhook = true
		} else if r.body.contains('"webhook_url"') {
			webhook = ''
			has_webhook = true
		}
	}
	if has_webhook {
		bot_upsert_webhook(mut d, bid, webhook, now_epoch())
	}
	return present(BotEdited{
		id:      bot.id
		name:    bot.name
		key:     c.bot_key_of(bot.id, bot_token_of(mut d, bot.id))
		webhook: bot_webhook(mut d, bot.id)
	})
}

pub struct BotEdited {
pub mut:
	id      i64
	name    string
	key     string
	webhook string
}

fn db_update_user_name(mut d database.DB, id i64, name string, now i64) {
	d.exec_none('UPDATE users SET name=?, updated_at=? WHERE id=?', [
		name,
		to_db_time(now),
		id.str(),
	]) or {}
}

// bot_key_reset resets a bot token.
pub fn bot_key_reset(mut d database.DB, r Req) Resp {
	uid := actor_or_login(r)
	if uid == -1 {
		return login_redirect()
	}
	if !admin_or_403(mut d, uid) {
		return err_resp('forbidden', 403)
	}
	bid := int_path_arg(r, 'id')
	bot := user(mut d, bid) or { return err_resp('not found', 404) }
	if bot.role != c.role_bot || bot.status != 0 {
		return err_resp('not found', 404)
	}
	token := random_bot_token()
	set_bot_token(mut d, bid, token, now_epoch())
	return present(BotKeyReset{ id: bid, key: c.bot_key_of(bid, token) })
}

pub struct BotKeyReset {
pub mut:
	id  i64
	key string
}

// styles_show serves the custom styles.
pub fn styles_show(mut d database.DB, r Req) Resp {
	uid := actor_or_login(r)
	if uid == -1 {
		return login_redirect()
	}
	if !admin_or_403(mut d, uid) {
		return err_resp('forbidden', 403)
	}
	account := account_row(mut d)
	styles := if acc := account { acc.custom_styles } else { '' }
	return present(CustomStyles{ custom_styles: styles })
}

pub struct CustomStyles {
pub mut:
	custom_styles string
}

// styles_update replaces the custom styles.
pub fn styles_update(mut d database.DB, r Req) Resp {
	uid := actor_or_login(r)
	if uid == -1 {
		return login_redirect()
	}
	if !admin_or_403(mut d, uid) {
		return err_resp('forbidden', 403)
	}
	account := account_row(mut d) or { return err_resp('not found', 404) }
	mut styles := ''
	if r.body != '' {
		payload := json.decode(StylesPayload, r.body) or { StylesPayload{} }
		if payload.account.custom_styles != '' || r.body.contains('"custom_styles"') {
			styles = payload.account.custom_styles
		} else {
			styles = payload.custom_styles
		}
	}
	if styles == '' {
		styles = form_or_json(r, 'custom_styles', '')
	}
	update_styles(mut d, account.id, styles, now_epoch()) or {
		return err_resp('unprocessable', 422)
	}
	return present(CustomStyles{ custom_styles: styles })
}

struct StylesPayload {
pub mut:
	custom_styles string
	account       StylesPayloadInner
}

struct StylesPayloadInner {
pub mut:
	custom_styles string
}

// join_code_reset resets the account join code.
pub fn join_code_reset(mut d database.DB, r Req) Resp {
	uid := actor_or_login(r)
	if uid == -1 {
		return login_redirect()
	}
	if !admin_or_403(mut d, uid) {
		return err_resp('forbidden', 403)
	}
	account := account_row(mut d) or { return err_resp('not found', 404) }
	code := reset_join_code(mut d, account.id, now_epoch())
	return present(JoinCodeView{ join_code: code, join_url: '/join/' + code })
}

pub struct JoinCodeView {
pub mut:
	join_code string
	join_url  string
}

// ban bans or unbans a user.
pub fn ban(mut d database.DB, r Req) Resp {
	uid := actor_or_login(r)
	if uid == -1 {
		return login_redirect()
	}
	if !admin_or_403(mut d, uid) {
		return err_resp('forbidden', 403)
	}
	other := int_path_arg(r, 'id')
	if user(mut d, other) == none {
		return err_resp('not found', 404)
	}
	now := now_epoch()
	if r.method == 'DELETE' {
		unban_user(mut d, other, now)
		return present(BanStatus{ id: other, status: 0 })
	}
	count := ban_user(mut d, other, now)
	return present(BanStatusFull{ id: other, status: 2, banned_ips: count })
}

pub struct BanStatus {
pub mut:
	id     i64
	status i64
}

pub struct BanStatusFull {
pub mut:
	id         i64
	status     i64
	banned_ips i64
}
