import { Image } from "expo-image";
import { StyleSheet, Text, View, ImageSourcePropType } from "react-native";
import {
  FontFamily,
  FontSize,
  Border,
  Color,
  Gap,
  Padding,
} from "@/GlobalStyles";

export type HistoryRowType = {
  image?: ImageSourcePropType;
  caption?: string;
  amount?: string;
};

const HistoryRow = ({ image, caption, amount }: HistoryRowType) => {
  return (
    <View style={[styles.frameParent, styles.frameFlexBox]}>
      <View style={[styles.frameGroup, styles.frameFlexBox]}>
        <Image
          source={image}
          style={[
            styles.frameChild,
            {
              width: 32,
              height: 32,
            },
          ]}
        />
        <View style={styles.captionParent}>
          <Text style={styles.caption}>{caption}</Text>
        </View>
      </View>
      <View style={styles.amountParent}>
        <Text style={[styles.amount, styles.textTypo]}>{amount}</Text>
      </View>
    </View>
  );
};

const styles = StyleSheet.create({
  frameFlexBox: {
    alignItems: "center",
    flexDirection: "row",
  },
  textTypo: {
    textAlign: "right",
    fontFamily: FontFamily.textMdL24Regular,
    fontSize: FontSize.size_2xs,
    alignSelf: "stretch",
  },
  frameChild: {
    borderRadius: Border.br_39xl,
    overflow: "hidden",
  },
  caption: {
    fontSize: FontSize.caption_size,
    fontWeight: "500",
    fontFamily: FontFamily.interMedium,
    textAlign: "left",
    color: Color.dardColor,
    alignSelf: "stretch",
  },
  // amount: {
  //   color: Color.taglineColor,
  //   display: "none",
  //   fontFamily: FontFamily.textMdL24Regular,
  //   fontSize: FontSize.size_2xs,
  //   textAlign: "left",
  //   alignSelf: "stretch",
  // },
  captionParent: {
    flex: 1,
    gap: Gap.gap_4xs,
  },
  frameGroup: {
    width: 178,
    gap: Gap.gap_3xs,
  },
  amount: {
    color: Color.dardColor,
    textAlign: "right",
  },
  text: {
    color: Color.primaryColor,
    display: "none",
  },
  amountParent: {
    width: 72,
    gap: Gap.gap_4xs,
  },
  frameParent: {
    borderRadius: Border.br_5xs,
    backgroundColor: Color.widgetBackground,
    borderStyle: "solid",
    borderColor: Color.colorGreen_100,
    borderWidth: 1,
    justifyContent: "space-between",
    padding: Padding.p_xs,
    alignSelf: "stretch",
    flexDirection: "row",
  },
});

export default HistoryRow;
