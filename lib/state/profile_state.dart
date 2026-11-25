import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/scooter_model.dart';
import '../providers/mock_provider.dart';
import 'toast_state.dart';

class UserProfile {
  const UserProfile({
    this.name = 'Owner',
    this.scooterName = 'My S1 Pro',
    this.registrationNumber = 'KL 01 AB 1234',
    this.purchaseDate = '2024-03-15',
    this.vehicleModel = 'S1 Pro',
    this.isPrimary = true,
  });

  final String name;
  final String scooterName;
  final String registrationNumber;
  final String purchaseDate;
  final String vehicleModel;
  final bool isPrimary;

  UserProfile copyWith({String? name, String? scooterName, String? registrationNumber}) => UserProfile(
        name: name ?? this.name,
        scooterName: scooterName ?? this.scooterName,
        registrationNumber: registrationNumber ?? this.registrationNumber,
        purchaseDate: purchaseDate,
        vehicleModel: vehicleModel,
        isPrimary: isPrimary,
      );
}

final profileProvider = NotifierProvider<ProfileNotifier, UserProfile>(ProfileNotifier.new);

/// Editing waits for a keyboard path in Phase 2; the setters exist so a
/// paired keyboard can drive them later.
///
/// On the head unit only the two names HHMIS sends are
/// real (`STR_PROFILE_USER_NAME`, `STR_PROFILE_SCOOTER_NAME`). Registration,
/// purchase date and the owner flag arrive in stock through callback TX 5
/// `onNewProfileDetailFetched`, which no log has captured yet, so they stay
/// empty and their rows are hidden.
// TODO(profile-details): registration, purchase date and the owner flag stay empty until a log captures
// callback TX 5 (onNewProfileDetailFetched) and its layout is read.
class ProfileNotifier extends Notifier<UserProfile> {
  @override
  UserProfile build() {
    if (!useAidlVehicle) return const UserProfile();
    final (name, scooter, type) = ref.watch(vehicleProvider.select((v) => (v.profileUserName, v.scooterBtName, v.vehicleType)));
    return UserProfile(
      name: name,
      scooterName: scooter,
      vehicleModel: ScooterModel.label(type),
      registrationNumber: '',
      purchaseDate: '',
      isPrimary: false,
    );
  }

  void setName(String v) => state = state.copyWith(name: v);
  void setScooterName(String v) => state = state.copyWith(scooterName: v);
  void setRegistration(String v) => state = state.copyWith(registrationNumber: v);

  void requestEdit() =>
      ref.read(toastProvider.notifier).show('Editing requires a keyboard (Phase 2)');

  void addRider() =>
      ref.read(toastProvider.notifier).show('Multi-rider coming in a future update');
}
