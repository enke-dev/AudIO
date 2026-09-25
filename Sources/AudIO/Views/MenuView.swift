import SwiftUI

/// The panel content, laid out like the system's Sound menu.
struct MenuView: View {
    @EnvironmentObject private var router: Router

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            MenuTitleView()
            if let notice = router.notice {
                MenuNoticeView(notice: notice)
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
