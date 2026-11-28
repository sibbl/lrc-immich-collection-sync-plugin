local dialogs, tasks = {}, {}
local function view(_, options) return options end
local factory = {
	column = view, row = view, static_text = view, edit_field = view, push_button = view,
	control_spacing = function() return 4 end,
}
registerLrMock('LrDialogs', dialogs)
registerLrMock('LrFunctionContext', tasks)
registerLrMock('LrView', { osFactory = function() return factory end, bind = function(key) return key end })
registerLrMock('LrBinding', { makePropertyTable = function() return {} end })
local RetryDialog = require 'RetryDialog'
local Settings = require 'Settings'
resetLrMocks()

describe('RetryDialog', function()
	it('reuses the original selection and requires Apply on the refreshed preview', function()
		local pending
		tasks.postAsyncTaskWithContext = function(_, fn)
			assertNil(pending)
			pending = fn
		end
		local selected = { direction = 'lr_to_immich' }
		local setups, attempts = 0, 0
		local applied
		RetryDialog.run('sync', function()
			setups = setups + 1
			return selected
		end, function(context, selection)
			attempts = attempts + 1
			assertEq(selection, selected)
			local choice = RetryDialog.preview(context, {
				text = 'Preview ' .. attempts,
				hasChanges = attempts > 1,
				hasDiagnostics = attempts <= 2,
			})
			if choice == 'apply' then applied = attempts end
			return choice
		end)

		local function click(action, expectedPrimary, expectedOther)
			dialogs.presentModalDialog = function(args)
				assertEq(args.actionVerb, expectedPrimary)
				assertEq(args.otherVerb, expectedOther)
				assertEq(args.contents.bind_to_object.preview, 'Preview ' .. attempts)
				return action
			end
			local nextAttempt = pending
			pending = nil
			nextAttempt({})
		end

		click('other', 'Close', 'Retry')
		assertNil(applied)
		click('other', 'Apply', 'Retry')
		assertNil(applied)
		click('ok', 'Apply', nil)
		assertEq(applied, 3)
		assertEq(setups, 1)
		assertNil(pending)
	end)

	it('finishes on Close, Escape, or Cancel without applying or retrying', function()
		dialogs.presentModalDialog = function() return 'ok' end
		assertNil(RetryDialog.preview({}, { hasDiagnostics = true }))
		assertNil(RetryDialog.preview({}, {}))
		dialogs.presentModalDialog = function() return 'cancel' end
		assertNil(RetryDialog.preview({}, { hasChanges = true, hasDiagnostics = true }))
		assertNil(RetryDialog.preview({}, { hasDiagnostics = true }))
	end)

	it('opens another attempt only when Retry is chosen on an error', function()
		dialogs.confirm = function(_, _, action, cancel)
			assertEq(action, 'Retry')
			assertEq(cancel, 'Close')
			return 'ok'
		end
		assertEq(RetryDialog.problem({}, 'Album unavailable', 'Connection failed'), 'retry')
		dialogs.confirm = function() return 'cancel' end
		assertNil(RetryDialog.problem({}, 'Album unavailable', 'Connection failed'))
	end)

	it('keeps a canceled mapping edit in the warning and retries with a saved prefix', function()
		local previous = Settings.getPathMappings()
		Settings.setPathMappings({})
		local editorChoice = 'cancel'
		local warningResult, resultAfterCancel
		dialogs.stopModalWithResult = function(_, result) warningResult = result end
		dialogs.presentModalDialog = function(args)
			if args.accessoryView then
				local button = args.accessoryView
				button.action(button)
				resultAfterCancel = warningResult
				editorChoice = 'ok'
				button.action(button)
				return warningResult
			end
			local entry = args.contents.bind_to_object
			entry.immich = '/data/library'
			entry.local_ = '/Volumes/photos'
			return editorChoice
		end
		local missing, action = RetryDialog.requirePathMappings({})
		local refreshed = RetryDialog.requirePathMappings({})
		Settings.setPathMappings(previous)
		assertNil(resultAfterCancel)
		assertNil(missing)
		assertEq(action, 'retry')
		assertEq(refreshed[1].immich, '/data/library/')
		assertEq(refreshed[1].local_, '/Volumes/photos')
	end)
end)
