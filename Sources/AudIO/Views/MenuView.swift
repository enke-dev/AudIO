import SwiftUI

/// The panel content, laid out like the system's Sound menu.
struct MenuView: View {
    @EnvironmentObject private var router: Router
    @EnvironmentObject private var updater: Updater

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            MenuTitleView()
            if let notice = router.notice {
                MenuNoticeView(
                    notice: notice,
                    dismiss: { router.dismissActionError() },
                    hold: { router.holdActionError($0) }
                )
            } else if case .failed(let message) = updater.state {
                // Why the update failed – "Update Failed" in the corner retries.
                MenuNoticeView(notice: .init(text: message, isError: true))
            }
            if router.driver != nil {
                MasterVolumeView()
            }
            MenuSeparator()
            MenuSectionHeader(title: "Outputs")
            ForEach(router.devices) { device in
                let isSelected = router.routes[device.uid]?.isSelected == true
                DeviceRow(uid: device.uid)
                // Revealed like a curtain: the frame grows from the row's bottom edge and
                // clips the (static) content – no fading, no sliding of the content itself.
                DeviceDetail(uid: device.uid)
                    .frame(height: isSelected ? DeviceDetail.height : 0, alignment: .top)
                    .clipped()
                    .allowsHitTesting(isSelected)
                    .accessibilityHidden(!isSelected)
            }
            ForEach(router.bluetoothDevices) { device in
                BluetoothRow(device: device)
            }
            MenuSeparator()
            MenuActionsView()
            MenuSeparator()
            MenuQuitRow()
        }
        .padding(.top, 6)
        .padding(.bottom, 5)
        .frame(width: MenuMetrics.width)
        .focusEffectDisabled() // no focus ring on the first row when the panel opens
    }
}
