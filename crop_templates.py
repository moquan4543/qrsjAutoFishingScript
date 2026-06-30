import os
import cv2
import numpy as np

def imread_unicode(path):
    return cv2.imdecode(np.fromfile(path, dtype=np.uint8), cv2.IMREAD_COLOR)

def main():
    img_dir = os.path.dirname(os.path.abspath(__file__))
    state_img_dir = os.path.join(img_dir, "stateImages")
    crop_dir = os.path.join(state_img_dir, "cropped")
    os.makedirs(crop_dir, exist_ok=True)
    
    # Define file names
    files = {
        "03": "03-成功下竿等待魚咬鉤.png",
        "04": "04-上鉤需在中間進度條見底前(5秒內)按下左鍵收線.png",
        "06": "06-途中會隨機出現向右拉提示,需長按D向左右拉直至提示消失.png",
        "07": "07-途中會隨機出現向左拉提示,需長按A向左拉直至提示消失.png",
        "08": "08-待魚的體力條耗盡後即可釣上,等待6秒動畫後按下F收魚,回到釣竿就緒狀態.png"
    }
    
    # We will search the folder for files that start with "03-", "04-", etc. in case the name varies slightly
    state_files = os.listdir(state_img_dir)
    for key in files:
        matched = [f for f in state_files if f.startswith(key + "-")]
        if matched:
            files[key] = matched[0]
            
    print("Found files mapping:")
    for k, v in files.items():
        print(f"  {k} -> {v}")
        
    # Read files
    img03 = imread_unicode(os.path.join(state_img_dir, files["03"]))
    img04 = imread_unicode(os.path.join(state_img_dir, files["04"]))
    img06 = imread_unicode(os.path.join(state_img_dir, files["06"]))
    img07 = imread_unicode(os.path.join(state_img_dir, files["07"]))
    img08 = imread_unicode(os.path.join(state_img_dir, files["08"]))
    
    if any(x is None for x in [img03, img04, img06, img07, img08]):
        print("Error: Could not load all state images. Please verify files exist in stateImages/.")
        return

    # Define crop ratios (y1, y2, x1, x2) based on 1534x862 reference
    # 1. State 3 (Waiting for bite)
    # y: 760-830, x: 740-800
    ratios_3 = (760/862, 830/862, 740/1534, 800/1534)
    
    # 2. State 4 (Hooked progress bar)
    # y: 730-760, x: 740-800
    ratios_4 = (730/862, 760/862, 740/1534, 800/1534)
    
    # 3. State 8 (Catch / press F)
    # y: 740-820, x: 720-810
    ratios_8 = (740/862, 820/862, 720/1534, 810/1534)
    
    # 4. QTE Right (D)
    # y: 555-605, x: 595-635
    ratios_qte_r = (555/862, 605/862, 595/1534, 635/1534)
    
    # 5. QTE Left (A)
    # y: 560-595, x: 680-725
    ratios_qte_l = (560/862, 595/862, 680/1534, 725/1534)

    def crop_by_ratio(img, ratios):
        h, w, _ = img.shape
        y1 = int(round(ratios[0] * h))
        y2 = int(round(ratios[1] * h))
        x1 = int(round(ratios[2] * w))
        x2 = int(round(ratios[3] * w))
        return img[y1:y2, x1:x2]

    # Save crops
    cv2.imwrite(os.path.join(crop_dir, "state3_indicator.png"), crop_by_ratio(img03, ratios_3))
    cv2.imwrite(os.path.join(crop_dir, "state4_indicator.png"), crop_by_ratio(img04, ratios_4))
    cv2.imwrite(os.path.join(crop_dir, "state8_indicator.png"), crop_by_ratio(img08, ratios_8))
    cv2.imwrite(os.path.join(crop_dir, "qte_right.png"), crop_by_ratio(img06, ratios_qte_r))
    cv2.imwrite(os.path.join(crop_dir, "qte_left.png"), crop_by_ratio(img07, ratios_qte_l))
    
    print("Successfully generated all cropped templates in stateImages/cropped/")

if __name__ == "__main__":
    main()
