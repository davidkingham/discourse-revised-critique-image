import { apiInitializer } from "discourse/lib/api";
import RevisedImageBanner from "../components/revised-image-banner";

export default apiInitializer((api) => {
  api.renderInOutlet("topic-above-posts", RevisedImageBanner);
});
